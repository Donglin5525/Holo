//
//  ThoughtSemanticEmbeddingExecutor.swift
//  Holo
//
//  embedding 任务执行器（语义图谱 V3 Phase 3，方案 §9.2 步骤 4 / §13.4）
//
//  领取 semantic_job → flag 与授权校验 → 读正文（纯图/空文 textUnavailable 合法完成）
//  → 确定性脱敏（ThoughtIndexV2Policy）→ 后端 embeddings（最小批次）→ L2 归一化
//  → SQLite 真身 + 索引 upsert → 任务终态。网络类失败指数退避，协议类错误终态。
//

import CoreData
import Foundation
import OSLog

actor ThoughtSemanticEmbeddingExecutor {

    static let shared = ThoughtSemanticEmbeddingExecutor()

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtSemanticEmbed")
    private var running = false
    private let maxAttempts = 3

    /// 每轮最多处理条数（§13.3：每轮 ≤64；执行器节拍由 pipeline 控制）
    func processBatch(limit: Int = 16,
                      store: ThoughtSemanticStore,
                      index: (any LocalSemanticIndex)?) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let flag = await MainActor.run { ThoughtSemanticFeatureFlags.index }
        guard flag != .off else { return }

        var processed = 0
        while processed < limit {
            let claimed: ThoughtSemanticStore.SemanticJob? =
                (try? await store.claimNextDueJob(consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration)) ?? nil
            guard let job = claimed else { break }
            processed += 1
            await run(job: job, store: store, index: index)
        }
    }

    private func run(job: ThoughtSemanticStore.SemanticJob,
                     store: ThoughtSemanticStore,
                     index: (any LocalSemanticIndex)?) async {
        // 1. 本地快照：未删除 Thought；纯图/空文本合法完成为 textUnavailable（§9.2 步骤 1）
        let snapshot: (id: UUID, text: String)? = await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            var out: (UUID, String)?
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", job.thoughtID as CVarArg)
                request.fetchLimit = 1
                if let thought = (try? context.fetch(request))?.first {
                    out = (thought.id, thought.content)
                }
            }
            return out
        }
        guard let snapshot else {
            // 想法已删/软删：任务完成，向量槽位已在 feed 侧 tombstone
            try? await store.finishJob(id: job.id, state: "done", errorCode: "thought_unavailable")
            return
        }
        let redacted = ThoughtIndexV2Policy.redactedText(forUpload: snapshot.text)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? await store.finishJob(id: job.id, state: "done", errorCode: "text_unavailable")
            return
        }
        // 版本判定（步骤 2）：相同 hash/model 已完成则跳过
        if (try? await store.hasActiveItem(thoughtID: snapshot.id, contentHash: job.contentHash,
                                           modelVersion: ThoughtSemanticStore.defaultModelVersion)) == true {
            try? await store.finishJob(id: job.id, state: "done")
            return
        }

        // 2. embedding：单条最小请求（批量属回填调度器，Phase 4）
        do {
            let provider = await MainActor.run { HoloBackendAIProvider() }
            let vectors = try await provider.embed(texts: [redacted])
            guard let raw = vectors.first, !raw.isEmpty else {
                throw ThoughtSemanticExecutorError.emptyVector
            }
            var vector = raw.map(Float.init)
            vector = SemanticVectorMath.normalized(vector)

            // 2.5 提交前复核（P0，2026-09-24 方案 §3）：embed 网络往返期间正文可能
            // 已编辑/软删、授权可能已撤回——迟到结果以提交时刻现场为准丢弃；
            // 编辑场景 feed 已为新版正文入队，无需补排
            guard await revalidateBeforeCommit(thoughtID: snapshot.id,
                                               expectedHash: job.contentHash,
                                               jobConsentGeneration: job.consentGeneration) else {
                try? await store.finishJob(id: job.id, state: "done", errorCode: "stale_result_dropped")
                logger.notice("迟到向量丢弃 thought=\(job.thoughtID)（正文已变/已删/授权已撤回）")
                return
            }

            // 3. 原子落库：真身 + 索引同一轮更新（索引失败不回滚真身，可重建）
            let key = try await store.allocateVectorKey()
            let item = ThoughtSemanticStore.SemanticItem(
                id: snapshot.id, contentHash: job.contentHash,
                modelVersion: ThoughtSemanticStore.defaultModelVersion,
                dimension: vector.count, vectorKey: key, state: "active", priority: 0,
                lastAccessedAt: Date(), updatedAt: Date())
            try await store.upsertItem(item, vector: vector.map(Float16.init))
            if let index {
                try? await index.upsert(id: snapshot.id, vector: vector,
                                        metadata: SemanticIndexMetadata(thoughtID: snapshot.id,
                                                                        contentHash: job.contentHash,
                                                                        modelVersion: item.modelVersion,
                                                                        dimension: vector.count))
                try? await index.checkpoint()
            }
            try? await store.finishJob(id: job.id, state: "done")
            // relate 任务化（2026-09-27 P0-C）：不再内联执行——入队由
            // ThoughtSemanticRelateExecutor 消费（失败退避重试、可恢复、
            // 存量补跑同一条队列）。relation flag 由消费侧判定，此处只入队。
            await enqueueRelateJob(thoughtID: snapshot.id, contentHash: job.contentHash, store: store)
        } catch {
            let attempt = job.attemptCount + 1
            // 协议/数据类错误直接终态；网络类退避重试（指数，封顶 1h）
            let terminal = isTerminalError(error)
            let next = Date().addingTimeInterval(min(60 * pow(2, Double(attempt)), 3600))
            try? await store.finishJob(id: job.id,
                                       state: (terminal || attempt >= maxAttempts) ? "failed_terminal" : "pending",
                                       nextAttemptAt: terminal ? nil : next,
                                       errorCode: errorCode(for: error))
            logger.error("embed 失败 thought=\(job.thoughtID) attempt=\(attempt) terminal=\(terminal) code=\(self.errorCode(for: error))")
        }
    }

    /// 提交前复核：ID 仍存在、未软删、当前正文 hash 与 job 一致、授权代数未变且授权仍有效。
    private func revalidateBeforeCommit(thoughtID: UUID,
                                        expectedHash: String,
                                        jobConsentGeneration: Int64) async -> Bool {
        await MainActor.run {
            guard ThoughtSemanticFeatureFlags.consentGeneration == jobConsentGeneration,
                  HoloAIDataProcessingConsent.shared.isGranted else { return false }
            let context = CoreDataStack.shared.viewContext
            var valid = false
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", thoughtID as CVarArg)
                request.fetchLimit = 1
                if let thought = (try? context.fetch(request))?.first,
                   let content = thought.value(forKey: "content") as? String,
                   ThoughtEmbeddingStore.contentHash(of: content) == expectedHash {
                    valid = true
                }
            }
            return valid
        }
    }

    /// relate 任务入队（P0-C）：embed 完成即入队，去重交给 hasPendingJob。
    /// 注意向量刚写入，loadVector 在消费侧必能读回。
    private func enqueueRelateJob(thoughtID: UUID,
                                  contentHash: String,
                                  store: ThoughtSemanticStore) async {
        do {
            guard try await !store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "relate") else {
                return
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "relate",
                priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, lastErrorCode: nil)
            try await store.enqueueJob(job)
        } catch {
            logger.error("relate 入队失败 thought=\(thoughtID)：\(error.localizedDescription)")
        }
    }

    private func isTerminalError(_ error: Error) -> Bool {
        if case ThoughtSemanticExecutorError.emptyVector = error { return true }
        let ns = error as NSError
        // 4xx 类协议错误（401/403/413/422）不重试；429/5xx/网络错误重试
        return (400...428).contains(ns.code) && ns.domain != NSURLErrorDomain
    }

    private func errorCode(for error: Error) -> String {
        if case ThoughtSemanticExecutorError.emptyVector = error { return "empty_vector" }
        return "network_or_upstream"
    }
}

enum ThoughtSemanticExecutorError: Error {
    case emptyVector
}
