//
//  HoloAgentPersistenceManager.swift
//  Holo
//
//  Agent V3.1 — Task 1.4 持久化协调器：统一编排 evidence / checkpoint / job / result 的写入顺序与引用校验
//

import Foundation

/// Phase 2 真实 `HoloEvidenceLedger` 将 conform 此协议；Phase 1 用 in-memory mock 隔离测试。
/// §5.5：load 改 throws（权限/数据保护/损坏不得当空库）；非 throwing 实现仍满足该要求。
protocol HoloEvidenceLedgerProtocol: Sendable {
    func load() async throws -> [HoloEvidenceRecord]
    func upsert(_ records: [HoloEvidenceRecord]) async throws
}

/// Agent 持久化协调器。
///
/// 职责：
/// - `saveProgress` 保证写入顺序 evidence → checkpoint → job（先落证据，再落快照，最后落任务状态）。
/// - `validateCheckpoint` 校验 checkpoint 引用的 evidence 是否都存在（防止悬空引用）。
/// - `cleanupOrphanedEvidence` 归档孤儿证据（protocol 仅支持 upsert，故用 `.archived` 软删除）。
actor HoloAgentPersistenceManager {

    private let evidenceLedger: HoloEvidenceLedgerProtocol
    /// 模块内可访问：HoloAgentConsistencyReconciler 需要直接读写三个 store（§5.4）。
    let checkpointStore: HoloAgentCheckpointStore
    let jobStore: HoloAgentJobStore
    let resultStore: HoloAgentResultStore
    /// 多 store 写入的事务闸门：记录写入意图，崩溃后供 Reconciler 精确恢复（§11.8）。
    let transactionGate: HoloAgentPersistenceTransactionGate

    init(evidenceLedger: HoloEvidenceLedgerProtocol,
         checkpointStore: HoloAgentCheckpointStore,
         jobStore: HoloAgentJobStore,
         resultStore: HoloAgentResultStore,
         transactionGate: HoloAgentPersistenceTransactionGate? = nil) {
        self.evidenceLedger = evidenceLedger
        self.checkpointStore = checkpointStore
        self.jobStore = jobStore
        self.resultStore = resultStore
        self.transactionGate = transactionGate ?? HoloAgentPersistenceTransactionGate()
    }

    /// 写入顺序：evidence → checkpoint → job。
    /// 先落证据可保证后续校验有据可依；最后落 job 状态，使外部观察到的 state 与已持久化的内容一致。
    /// 每步经事务闸门记录，崩溃后 Reconciler 据残留 journal 精确恢复（§11.8）。
    func saveProgress(
        job: HoloAgentJob,
        evidence: [HoloEvidenceRecord],
        checkpoint: HoloAgentCheckpoint
    ) async throws {
        await transactionGate.record(jobID: job.id, step: .begin)
        try await evidenceLedger.upsert(evidence)
        await transactionGate.record(jobID: job.id, step: .evidenceWritten)
        try await checkpointStore.upsert(checkpoint)
        await transactionGate.record(jobID: job.id, step: .checkpointWritten)
        try await jobStore.upsert(job)
        await transactionGate.record(jobID: job.id, step: .jobWritten)
        await transactionGate.record(jobID: job.id, step: .committed)
        await transactionGate.clear(jobID: job.id)
    }

    /// 写入 Agent 最终结果（final_claims 产出）。
    func saveResult(_ result: HoloAgentResult) async throws {
        try await resultStore.upsert(result)
    }

    /// 读取最近一条 Agent 结果（按 generatedAt 降序），供记忆长廊展示。
    func loadLatestResult() async throws -> HoloAgentResult? {
        try await resultStore.latest()
    }

    /// 读取指定 job 的结果，供 Chat 恢复时回填原消息。
    func loadResult(jobID: String) async throws -> HoloAgentResult? {
        try await resultStore.forJob(jobID: jobID)
    }

    /// 读取指定 IDs 的 evidence 记录，供结果渲染引用（Phase 6.3 evidence 引用）。
    func loadEvidence(forIDs ids: [String]) async throws -> [HoloEvidenceRecord] {
        let idSet = Set(ids)
        return try await evidenceLedger.load().filter { idSet.contains($0.id) }
    }

    /// 校验 checkpoint 引用的 evidence 是否都存在于 ledger。
    func validateCheckpoint(_ checkpoint: HoloAgentCheckpoint) async throws -> Bool {
        let evidenceIDs = Set(try await evidenceLedger.load().map(\.id))
        return checkpoint.evidenceRecordIDs.allSatisfy { evidenceIDs.contains($0) }
    }

    /// 归档 orphaned 且超过保留期的证据，返回被归档的 recordIDs。
    @discardableResult
    func cleanupOrphanedEvidence(now: Date = Date(), retentionDays: Int = 7) async throws -> [String] {
        let all = try await evidenceLedger.load()
        var archived: [HoloEvidenceRecord] = []
        for record in all {
            if record.status == .orphaned,
               now.timeIntervalSince(record.generatedAt) > TimeInterval(retentionDays * 86_400) {
                var updated = record
                updated.status = .archived
                archived.append(updated)
            }
        }
        if !archived.isEmpty {
            try await evidenceLedger.upsert(archived)
        }
        return archived.map(\.id)
    }

    /// 清理终态且超保留期的 job 及其关联 checkpoint/result，返回被清理的 jobIDs（§9.6 体积治理）。
    /// 级联行为由 policy 三开关控制：
    /// - cascadeCheckpoint：是否级联删除关联 checkpoint（默认 true）
    /// - cascadeResult：是否级联删除关联 result（默认 true）
    /// - preserveReferencedEvidence：true 时 evidence 由独立 orphan 流程按引用标记驱动，
    ///   此处不触碰 evidence（默认 true）；false 时此处不额外动作（evidence 清理始终走 orphan 流程）。
    @discardableResult
    func cleanupTerminalJobs(policy: HoloJobCleanupPolicy, now: Date = Date()) async throws -> [String] {
        let removedJobIDs = try await jobStore.cleanup(policy: policy, now: now)
        if !removedJobIDs.isEmpty {
            if policy.cascadeCheckpoint {
                _ = try await checkpointStore.deleteByJobIDs(removedJobIDs)
            }
            if policy.cascadeResult {
                _ = try await resultStore.deleteByJobIDs(removedJobIDs)
            }
            // evidence 始终由 cleanupOrphanedEvidence 独立按 orphaned 标记驱动；
            // preserveReferencedEvidence 的语义已由 orphan 流程的引用计数保证——
            // 仍被其他 job/memory 引用的 evidence 不会被标记 orphaned。
        }
        return removedJobIDs
    }
}
