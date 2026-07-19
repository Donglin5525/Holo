//
//  HoloAgentRuntimeFactory.swift
//  Holo
//
//  HoloAI Agent V3.1 — Runtime 装配工厂
//  用生产持久化目录（Application Support/Holo/Memory/Agent）构造 mock runtime。
//  EvidenceLedger 已接入真实 `HoloEvidenceLedger`（Task 2.1）。
//

import Foundation

enum HoloAgentRuntimeFactory {

    /// 构造默认 mock runtime（生产持久化目录 + 真实 EvidenceLedger）。
    /// mock 阶段不接 LLM / 真实 tool，仅用于跑通可恢复生命周期与证据落盘。
    static func makeDefaultRuntime() -> HoloLocalAgentRuntime {
        let jobStore = HoloAgentJobStore()
        let checkpointStore = HoloAgentCheckpointStore()
        let resultStore = HoloAgentResultStore()
        let ledger = HoloEvidenceLedger()
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: resultStore
        )
        return HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            eventRecorder: HoloAgentEventStore.shared
        )
    }
}
