//
//  HoloAgentRuntimeShared.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 5.1 接线：App 生命周期共享入口
//  为 HoloApp scenePhase（5.1）与后续 ChatViewModel（6.2）提供单一 runtime / 续跑管理器。
//  仅在 HoloAIFeatureFlags.agentRuntimeEnabled 开启时被访问；默认关，零副作用。
//

import Foundation

struct HoloDefaultCrossDomainDataSource: HoloCrossDomainDataSource {
    func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow] {
        let healthKind: HoloHealthMetricKind? = switch source {
        case "health.steps": .steps
        case "health.sleep": .sleep
        case "health.stand": .stand
        case "health.activity": .activity
        default: nil
        }
        if let kind = healthKind {
            return await HoloDefaultHealthDataSource()
                .dailyRecords(for: kind, timeRange: timeRange)
                .filter { $0.value > 0 }
                .map { record in
                    HoloQueryRow(
                        id: "\(kind.rawValue)-\(Int(record.date.timeIntervalSince1970))",
                        occurredAt: record.date,
                        fields: ["date": .date(record.date), "value": .number(record.value)],
                        excerpt: "\(kind.rawValue) \(record.value)"
                    )
                }
        }
        if source == "finance.transactions" {
            return await HoloDefaultFinanceDataSource().queryRows(timeRange: timeRange, parameters: [:])
        }
        if source == "habit.daily" {
            let habits = await HoloDefaultHabitDataSource().habits(timeRange: timeRange)
            let calendar = Calendar.current
            let end = timeRange?.end ?? Date()
            let latestDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: end)) ?? end
            return habits.flatMap { habit in
                habit.dailyCounts.compactMap { count in
                    guard let date = calendar.date(byAdding: .day, value: -count.dayOffset, to: latestDay) else { return nil }
                    return HoloQueryRow(
                        id: "\(habit.id)-d\(count.dayOffset)",
                        occurredAt: date,
                        fields: [
                            "date": .date(date),
                            "value": .number(count.count),
                            "habit": .text(habit.name),
                            "polarity": .text(habit.polarity.rawValue)
                        ],
                        excerpt: "\(habit.name) \(count.count) 次"
                    )
                }
            }
        }
        return []
    }
}

extension HoloLocalAgentRuntime {
    /// 全 App 共享的生产 Agent runtime（真实后端 LLM + Memory 工具）。
    /// 同时服务后台续跑（Phase 5.1）与对话深度分析（Phase 6.2）。
    /// 生产 dataSource 已覆盖 10 类用户语义数据工具。
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
        let productionTools: [HoloDataTool] = [
            HoloMemoryTool(dataSource: HoloDefaultMemoryDataSource()),
            HoloHabitTool(dataSource: HoloDefaultHabitDataSource()),
            HoloHealthTool(dataSource: HoloDefaultHealthDataSource()),
            HoloFinanceTool(dataSource: HoloDefaultFinanceDataSource()),
            HoloGoalTool(dataSource: HoloDefaultGoalDataSource()),
            HoloThoughtTool(dataSource: HoloDefaultThoughtDataSource()),
            HoloTaskTool(dataSource: HoloDefaultTaskDataSource()),
            HoloProfileTool(dataSource: HoloDefaultProfileDataSource()),
            HoloConversationTool(dataSource: HoloDefaultConversationDataSource()),
            HoloInsightTool(dataSource: HoloDefaultInsightDataSource()),
            HoloCrossDomainTool(dataSource: HoloDefaultCrossDomainDataSource())
        ]
        assert(
            HoloAgentToolCoverage.missingToolNames(in: productionTools).isEmpty,
            "生产 Agent 工具注册不完整"
        )
        let registry = HoloToolRegistry(tools: productionTools)
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
    static let shared = HoloBackgroundContinuationManager(
        runtime: HoloLocalAgentRuntime.shared,
        scheduler: HoloAgentScheduler.shared
    )
}
