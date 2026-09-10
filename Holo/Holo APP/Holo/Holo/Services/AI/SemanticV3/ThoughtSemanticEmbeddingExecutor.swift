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
            await runShadowRelateIfNeeded(thoughtID: snapshot.id,
                                          redactedText: redacted,
                                          contentHash: job.contentHash,
                                          vector: vector,
                                          store: store,
                                          index: index)
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

    /// embed 完成后的影子关联评估（flag relation=shadow 时；失败静默不影响 embed 结果）。
    private func runShadowRelateIfNeeded(thoughtID: UUID,
                                         redactedText: String,
                                         contentHash: String,
                                         vector: [Float],
                                         store: ThoughtSemanticStore,
                                         index: (any LocalSemanticIndex)?) async {
        let flag = await MainActor.run { ThoughtSemanticFeatureFlags.relation }
        guard flag == .shadow else { return }
        let (calibration, _) = ThoughtSemanticCalibration.current()
        let provider = await MainActor.run { HoloBackendAIProvider() }
        let context = await MainActor.run { CoreDataStack.shared.viewContext }
        _ = await ThoughtTopicVerifier.shadowEvaluate(
            thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
            targetVector: vector, store: store, index: index,
            context: context, provider: provider, calibration: calibration)
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
