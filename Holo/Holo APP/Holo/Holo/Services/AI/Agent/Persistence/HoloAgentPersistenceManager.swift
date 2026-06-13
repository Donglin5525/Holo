//
//  HoloAgentPersistenceManager.swift
//  Holo
//
//  Agent V3.1 — Task 1.4 持久化协调器：统一编排 evidence / checkpoint / job / result 的写入顺序与引用校验
//

import Foundation

/// Phase 2 真实 `HoloEvidenceLedger` 将 conform 此协议；Phase 1 用 in-memory mock 隔离测试。
protocol HoloEvidenceLedgerProtocol: Sendable {
    func load() async -> [HoloEvidenceRecord]
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
    private let checkpointStore: HoloAgentCheckpointStore
    private let jobStore: HoloAgentJobStore
    private let resultStore: HoloAgentResultStore

    init(evidenceLedger: HoloEvidenceLedgerProtocol,
         checkpointStore: HoloAgentCheckpointStore,
         jobStore: HoloAgentJobStore,
         resultStore: HoloAgentResultStore) {
        self.evidenceLedger = evidenceLedger
        self.checkpointStore = checkpointStore
        self.jobStore = jobStore
        self.resultStore = resultStore
    }

    /// 写入顺序：evidence → checkpoint → job。
    /// 先落证据可保证后续校验有据可依；最后落 job 状态，使外部观察到的 state 与已持久化的内容一致。
    func saveProgress(
        job: HoloAgentJob,
        evidence: [HoloEvidenceRecord],
        checkpoint: HoloAgentCheckpoint
    ) async throws {
        try await evidenceLedger.upsert(evidence)
        try await checkpointStore.upsert(checkpoint)
        try await jobStore.upsert(job)
    }

    /// 写入 Agent 最终结果（final_claims 产出）。
    func saveResult(_ result: HoloAgentResult) async throws {
        try await resultStore.upsert(result)
    }

    /// 读取最近一条 Agent 结果（按 generatedAt 降序），供记忆长廊展示。
    func loadLatestResult() async -> HoloAgentResult? {
        await resultStore.latest()
    }

    /// 校验 checkpoint 引用的 evidence 是否都存在于 ledger。
    func validateCheckpoint(_ checkpoint: HoloAgentCheckpoint) async -> Bool {
        let evidenceIDs = Set(await evidenceLedger.load().map(\.id))
        return checkpoint.evidenceRecordIDs.allSatisfy { evidenceIDs.contains($0) }
    }

    /// 归档 orphaned 且超过保留期的证据，返回被归档的 recordIDs。
    @discardableResult
    func cleanupOrphanedEvidence(now: Date = Date(), retentionDays: Int = 7) async throws -> [String] {
        let all = await evidenceLedger.load()
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
}
