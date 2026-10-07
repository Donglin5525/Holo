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

    /// 每轮最多处理条数（§13.3：每轮 ≤64；执行器节拍由 pipeline 控制）
    func processBatch(limit: Int = 16,
                      store: ThoughtSemanticStore,
                      index: (any LocalSemanticIndex)?) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let flag = await MainActor.run { ThoughtSemanticFeatureFlags.index }
        guard flag != .off else { return }

        var jobs: [ThoughtSemanticStore.SemanticJob] = []
        while jobs.count < min(limit, 16) {
            guard ThoughtSemanticFeatureFlags.index != .off, await MainActor.run(body: { HoloAIDataProcessingConsent.shared.isGranted }) else { break }
            let claimed: ThoughtSemanticStore.SemanticJob? =
                (try? await store.claimNextDueJob(consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, kind: "embed")) ?? nil
            guard let job = claimed else { break }
            jobs.append(job)
        }
        await runBatch(jobs, store: store, index: index)
    }

    /// 普通笔记合并为最多 16 条的一次向量请求；长笔记仍逐段处理，历史回填不逐条消耗调用额度。
    private func runBatch(_ jobs: [ThoughtSemanticStore.SemanticJob], store: ThoughtSemanticStore,
                          index: (any LocalSemanticIndex)?) async {
        var batch: [(job: ThoughtSemanticStore.SemanticJob, text: String)] = []
        for job in jobs {
            let text: String? = await MainActor.run {
                let context = CoreDataStack.shared.viewContext
                return context.performAndWait {
                    let request = Thought.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", job.thoughtID as CVarArg)
                    return (try? context.fetch(request))?.first?.value(forKey: "content") as? String
                }
            }
            guard let text, ThoughtSemanticText.contentHash(text) == job.contentHash else {
                try? await store.finishJob(id: job.id, state: "done", errorCode: "stale_content")
                continue
            }
            let redacted = ThoughtIndexV2Policy.redactedText(forUpload: text)
            let alreadyIndexed = (try? await store.hasActiveItem(thoughtID: job.thoughtID, contentHash: job.contentHash,
                                                                modelVersion: ThoughtSemanticStore.defaultModelVersion)) == true
            if redacted.utf16.count > 2_000 || redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                alreadyIndexed {
                await run(job: job, store: store, index: index)
            } else { batch.append((job, redacted)) }
        }
        guard !batch.isEmpty else { return }
        do {
            guard ThoughtSemanticFeatureFlags.index != .off,
                  batch.allSatisfy({ $0.job.consentGeneration == ThoughtSemanticFeatureFlags.consentGeneration }),
                  await MainActor.run(body: { HoloAIDataProcessingConsent.shared.isGranted }) else { throw CancellationError() }
            let provider = await MainActor.run { HoloBackendAIProvider() }
            let response = try await provider.embedWithMetadata(texts: batch.map(\.text))
            guard response.dimensions == 1024, response.model == "text-embedding-v3", response.vectors.count == batch.count else {
                throw ThoughtSemanticExecutorError.emptyVector
            }
            let vectors = try response.vectors.map { raw -> [Float] in
                guard raw.count == 1024, raw.allSatisfy({ $0.isFinite }) else { throw ThoughtSemanticExecutorError.emptyVector }
                let vector = SemanticVectorMath.normalized(raw.map(Float.init))
                guard SemanticVectorMath.isNormalized(vector) else { throw ThoughtSemanticExecutorError.emptyVector }
                return vector
            }
            for (entry, vector) in zip(batch, vectors) {
                do { try await commitVector(vector, job: entry.job, store: store, index: index) }
                catch { await finishFailure(error, job: entry.job, store: store) }
            }
        } catch {
            if case APIError.backendError(_, let code, _, _) = error, code == "MODERATION_BLOCKED", batch.count > 1 {
                // 单条内容被拒绝不能连带阻止同批其他正常笔记。
                for entry in batch { await run(job: entry.job, store: store, index: index) }
            } else {
                for entry in batch { await finishFailure(error, job: entry.job, store: store) }
            }
        }
    }

    private func commitVector(_ vector: [Float], job: ThoughtSemanticStore.SemanticJob,
                              store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?) async throws {
        guard await revalidateBeforeCommit(thoughtID: job.thoughtID, expectedHash: job.contentHash,
                                          jobConsentGeneration: job.consentGeneration) else {
            try await store.finishJob(id: job.id, state: "done", errorCode: "stale_result_dropped")
            return
        }
        let key = try await store.allocateVectorKey()
        let item = ThoughtSemanticStore.SemanticItem(id: job.thoughtID, contentHash: job.contentHash,
            modelVersion: ThoughtSemanticStore.defaultModelVersion, dimension: vector.count, vectorKey: key,
            state: "active", priority: job.priority, lastAccessedAt: Date(), updatedAt: Date())
        try await store.upsertItem(item, vector: vector.map(Float16.init))
        if let index {
            try? await index.upsert(id: job.thoughtID, vector: vector,
                metadata: SemanticIndexMetadata(thoughtID: job.thoughtID, contentHash: job.contentHash,
                                                modelVersion: item.modelVersion, dimension: vector.count))
            try? await index.checkpoint()
        }
        try await store.finishJob(id: job.id, state: "done")
        await enqueueRelateJob(thoughtID: job.thoughtID, contentHash: job.contentHash, priority: job.priority, store: store)
    }

    private func finishFailure(_ error: Error, job: ThoughtSemanticStore.SemanticJob, store: ThoughtSemanticStore) async {
        let terminal = isTerminalError(error)
        let next = Date().addingTimeInterval(ThoughtSemanticRetryPolicy.delay(error, attempt: job.attemptCount + 1))
        try? await store.finishJob(id: job.id, state: terminal ? "failed_terminal" : "pending",
                                  nextAttemptAt: terminal ? nil : next, errorCode: errorCode(for: error))
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
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", job.thoughtID as CVarArg)
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
        guard ThoughtSemanticText.contentHash( snapshot.text) == job.contentHash else {
            try? await store.finishJob(id: job.id, state: "done", errorCode: "stale_content")
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
            await enqueueRelateJob(thoughtID: snapshot.id, contentHash: job.contentHash, priority: job.priority, store: store)
            return
        }

        // 2. embedding：单条最小请求（批量属回填调度器，Phase 4）
        do {
            let provider = await MainActor.run { HoloBackendAIProvider() }
            let chunks = ThoughtSemanticText.chunks(redacted, maxUTF16: 2_000)
            var vector = Array(repeating: Float(0), count: 1024)
            var totalWeight: Float = 0
            // 每次最多 16 段；整篇长文逐段编码，按字数加权归一化。
            for offset in stride(from: 0, to: chunks.count, by: 16) {
                guard ThoughtSemanticFeatureFlags.index != .off,
                      ThoughtSemanticFeatureFlags.consentGeneration == job.consentGeneration else { throw CancellationError() }
                let batch = Array(chunks[offset..<min(offset + 16, chunks.count)])
                let response = try await provider.embedWithMetadata(texts: batch.map(\.text))
                guard response.dimensions == 1024, response.model == "text-embedding-v3", response.vectors.count == batch.count else {
                    throw ThoughtSemanticExecutorError.emptyVector
                }
                for (chunk, raw) in zip(batch, response.vectors) {
                    guard raw.count == 1024, raw.allSatisfy({ $0.isFinite }) else { throw ThoughtSemanticExecutorError.emptyVector }
                    let normalized = SemanticVectorMath.normalized(raw.map(Float.init))
                    guard SemanticVectorMath.isNormalized(normalized) else { throw ThoughtSemanticExecutorError.emptyVector }
                    let weight = Float(chunk.text.utf16.count)
                    for i in vector.indices { vector[i] += normalized[i] * weight }
                    totalWeight += weight
                }
            }
            guard totalWeight > 0 else { throw ThoughtSemanticExecutorError.emptyVector }
            vector = SemanticVectorMath.normalized(vector)

            try await commitVector(vector, job: job, store: store, index: index)
        } catch {
            let attempt = job.attemptCount + 1
            // 协议/数据类错误直接终态；网络类退避重试（指数，封顶 1h）
            let terminal = isTerminalError(error)
            let next = Date().addingTimeInterval(ThoughtSemanticRetryPolicy.delay(error, attempt: attempt))
            try? await store.finishJob(id: job.id,
                                       state: terminal ? "failed_terminal" : "pending",
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
            guard ThoughtSemanticFeatureFlags.index != .off,
                  ThoughtSemanticFeatureFlags.consentGeneration == jobConsentGeneration,
                  HoloAIDataProcessingConsent.shared.isGranted else { return false }
            let context = CoreDataStack.shared.viewContext
            var valid = false
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", thoughtID as CVarArg)
                request.fetchLimit = 1
                if let thought = (try? context.fetch(request))?.first,
                   let content = thought.value(forKey: "content") as? String,
                   ThoughtSemanticText.contentHash( content) == expectedHash {
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
                                  priority: Int,
                                  store: ThoughtSemanticStore) async {
        do {
            guard try await !store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "relate") else {
                return
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "relate",
                priority: priority, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, lastErrorCode: nil)
            try await store.enqueueJob(job)
        } catch {
            logger.error("relate 入队失败 thought=\(thoughtID)：\(error.localizedDescription)")
        }
    }

    private func isTerminalError(_ error: Error) -> Bool {
        ThoughtSemanticRetryPolicy.isTerminal(error)
    }

    private func errorCode(for error: Error) -> String {
        if case ThoughtSemanticExecutorError.emptyVector = error { return "empty_vector" }
        return ThoughtSemanticRetryPolicy.code(error)
    }
}

enum ThoughtSemanticExecutorError: Error {
    case emptyVector
}
