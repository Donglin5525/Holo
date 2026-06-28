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
    /// 全 App 共享的生产 Agent runtime（真实后端 LLM + Memory 工具）。
    /// 同时服务后台续跑（Phase 5.1）与对话深度分析（Phase 6.2）。
    /// 生产 dataSource 已覆盖 memory/habit/health/finance/goal/thought/task 七类。
    /// 生产装配放此处（而非 Factory），避免 standalone test 拉 Factory 时引入后端重依赖。
    @MainActor
    static let shared: HoloLocalAgentRuntime = {
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
        let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
        let llmClient = HoloAgentLLMClient(provider: provider)
        let registry = HoloToolRegistry(tools: [
            HoloMemoryTool(dataSource: HoloDefaultMemoryDataSource()),
            HoloHabitTool(dataSource: HoloDefaultHabitDataSource()),
            HoloHealthTool(dataSource: HoloDefaultHealthDataSource()),
            HoloFinanceTool(dataSource: HoloDefaultFinanceDataSource()),
            HoloGoalTool(dataSource: HoloDefaultGoalDataSource()),
            HoloThoughtTool(dataSource: HoloDefaultThoughtDataSource()),
            HoloTaskTool(dataSource: HoloDefaultTaskDataSource())
        ])
        let toolExecutor = HoloToolExecutor(registry: registry)
        return HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            llmClient: llmClient,
            toolExecutor: toolExecutor
        )
    }()
}

extension HoloBackgroundContinuationManager {
    /// 全 App 共享的后台续跑管理器，绑定 shared runtime。
    static let shared = HoloBackgroundContinuationManager(runtime: HoloLocalAgentRuntime.shared)
}
