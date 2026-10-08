//
//  ThoughtSemanticRelateExecutor.swift
//  Holo
//
//  relate 任务执行器（2026-09-27 P0-C：relate 任务化）
//
//  领取 kind="relate" 的 semantic_job → 本地快照重验（未删 + hash 一致）→
//  读回向量 → 复用 Verifier（召回→semantic-relate→二次校验→分层→提交/记录）。
//  网络类失败指数退避重试，协议类错误终态——与 embed 执行器同一套队列纪律。
//
//  为什么独立任务化（方案 §5.1）：旧实现把 relate 内联在 embed 尾部——
//  已有向量的想法提前 return 导致 relation 开启后存量永不归类；失败即丢、
//  App 中途被杀无恢复。入队后补跑/重试/授权代数过滤全部免费获得。
//

import CoreData
import Foundation
import OSLog

actor ThoughtSemanticRelateExecutor {

    static let shared = ThoughtSemanticRelateExecutor()

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtSemanticRelate")
    private var running = false

    /// 每轮最多处理条数（relate 单条一次网络往返，批小于 embed）
    func processBatch(limit: Int = 8,
                      store: ThoughtSemanticStore,
                      index: (any LocalSemanticIndex)?) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let flag = await MainActor.run { ThoughtSemanticFeatureFlags.relation }
        guard flag != .off else { return }

        var processed = 0
        while processed < limit {
            guard ThoughtSemanticFeatureFlags.relation != .off, await MainActor.run(body: { HoloAIDataProcessingConsent.shared.isGranted }) else { break }
            let claimed: ThoughtSemanticStore.SemanticJob? =
                (try? await store.claimNextDueJob(
                    consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration,
                    kind: "relate")) ?? nil
            guard let job = claimed else { break }
            processed += 1
            await run(job: job, store: store, index: index)
            // 服务每分钟处理 20 次；历史队列串行匀速消费，避免刚恢复就再次撞限流。
            if processed < limit {
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
            }
        }
    }

    private func run(job: ThoughtSemanticStore.SemanticJob,
                     store: ThoughtSemanticStore,
                     index: (any LocalSemanticIndex)?) async {
        // 1. 本地快照重验：未删除且正文 hash 与任务一致（正文已变：feed 已为新版
        //    入队 embed→relate 全流程，本任务针对旧版本直接完成）
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
        // 2. 读回向量（真身 SQLite；无 active 向量=任务不应存在，防御性完成）
        guard (try? await store.hasActiveItem(thoughtID: snapshot.id, contentHash: job.contentHash, modelVersion: ThoughtSemanticStore.defaultModelVersion)) == true,
              let vector = (try? await store.loadVector(thoughtID: snapshot.id)) ?? nil,
              !vector.isEmpty else {
            try? await store.finishJob(id: job.id, state: "done", errorCode: "vector_unavailable")
            return
        }

        // 3. flag 与校准门（§6.2：无正式校准 JSON 一律 shadow）
        let flag = await MainActor.run { ThoughtSemanticFeatureFlags.relation }
        let calibration = ThoughtSemanticCalibration.current().config
        // 向量阈值只负责召回；正式写入必须通过 V2 契约的双侧原文证据校验。
        let commit = flag == .on

        do {
            let provider = await MainActor.run { HoloBackendAIProvider() }
            let context = CoreDataStack.shared.newBackgroundContext()
            if commit {
                _ = try await ThoughtTopicVerifier.evaluateAndCommit(
                    thoughtID: snapshot.id, redactedText: redacted, contentHash: job.contentHash,
                    targetVector: vector, store: store, index: index,
                    context: context, provider: provider, calibration: calibration,
                    consentGeneration: job.consentGeneration)
            } else {
                _ = try await ThoughtTopicVerifier.shadowEvaluate(
                    thoughtID: snapshot.id, redactedText: redacted, contentHash: job.contentHash,
                    targetVector: vector, store: store, index: index,
                    context: context, provider: provider, calibration: calibration,
                    consentGeneration: job.consentGeneration)
            }
            try await store.finishJob(id: job.id, state: "done")
        } catch {
            let attempt = job.attemptCount + 1
            let terminal = isTerminalError(error)
            let next = Date().addingTimeInterval(ThoughtSemanticRetryPolicy.delay(error, attempt: attempt))
            try? await store.finishJob(id: job.id,
                                       state: terminal ? "failed_terminal" : "pending",
                                       nextAttemptAt: terminal ? nil : next,
                                       errorCode: ThoughtSemanticRetryPolicy.code(error))
            logger.error("relate 失败 thought=\(job.thoughtID) attempt=\(attempt) terminal=\(terminal)：\(error.localizedDescription)")
        }
    }

    private func isTerminalError(_ error: Error) -> Bool {
        ThoughtSemanticRetryPolicy.isTerminal(error)
    }
}
