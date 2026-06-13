//
//  HoloAgentRuntimeShared.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 5.1 接线：App 生命周期共享入口
//  为 HoloApp scenePhase（5.1）与后续 ChatViewModel（6.2）提供单一 runtime / 续跑管理器。
//  仅在 HoloAIFeatureFlags.agentRuntimeEnabled 开启时被访问；默认关，零副作用。
//

import Foundation

extension HoloLocalAgentRuntime {
    /// 全 App 共享的 Agent runtime（生产持久化目录 + 真实 EvidenceLedger）。
    static let shared = HoloAgentRuntimeFactory.makeDefaultRuntime()
}

extension HoloBackgroundContinuationManager {
    /// 全 App 共享的后台续跑管理器，绑定 shared runtime。
    static let shared = HoloBackgroundContinuationManager(runtime: HoloLocalAgentRuntime.shared)
}
