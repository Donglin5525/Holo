//
//  HoloAgentRuntimeFactory.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 1.5 Runtime 装配工厂
//  用生产持久化目录（Application Support/Holo/Memory/Agent）构造 mock runtime。
//  Phase 1 的 EvidenceLedger 用占位实现，Phase 2 接入真实 `HoloEvidenceLedger` 后替换。
//

import Foundation

/// Phase 1 占位 Evidence Ledger：mock runtime 不产生真实证据，
/// 占位实现仅满足 `HoloEvidenceLedgerProtocol`，Phase 2 替换为带查重的 `HoloEvidenceLedger`。
actor HoloAgentPlaceholderEvidenceLedger: HoloEvidenceLedgerProtocol {
    private var records: [HoloEvidenceRecord] = []

    func load() -> [HoloEvidenceRecord] { records }

    func upsert(_ newRecords: [HoloEvidenceRecord]) {
        records.append(contentsOf: newRecords)
    }
}

enum HoloAgentRuntimeFactory {

    /// 构造默认 mock runtime（生产持久化目录 + 占位 ledger）。
    /// Phase 1 仅用于跑通可恢复生命周期，不接 LLM / 真实 tool。
    static func makeDefaultRuntime() -> HoloLocalAgentRuntime {
        let jobStore = HoloAgentJobStore()
        let checkpointStore = HoloAgentCheckpointStore()
        let resultStore = HoloAgentResultStore()
        let ledger = HoloAgentPlaceholderEvidenceLedger()
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: resultStore
        )
        return HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore
        )
    }
}
