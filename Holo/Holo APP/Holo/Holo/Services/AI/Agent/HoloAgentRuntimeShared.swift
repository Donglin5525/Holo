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
        if source == "task.daily" {
            return await Self.taskRows(timeRange: timeRange)
        }
        if source == "goal.progress.daily" {
            return await Self.goalProgressRows(timeRange: timeRange)
        }
        return []
    }

    private static func taskRows(timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow] {
        let (start, end, days) = dayRange(timeRange)
        return await MainActor.run {
            let tasks = TodoRepository.shared.getTasks(completedFrom: start, completedTo: end)
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: tasks) { task in
                calendar.startOfDay(for: task.completedAt ?? start)
            }
            return days.map { day in
                let records = grouped[day] ?? []
                let sourceIDs = records.map { $0.id.uuidString }
                return HoloQueryRow(
                    id: sourceIDs.isEmpty ? "task-day-\(Int(day.timeIntervalSince1970))" : sourceIDs.joined(separator: ","),
                    occurredAt: day,
                    fields: [
                        "date": .date(day),
                        "value": .number(Double(records.count)),
                        "highPriorityValue": .number(Double(records.filter { $0.priority >= 2 }.count))
                    ],
                    excerpt: "完成任务 \(records.count) 个，其中高优 \(records.filter { $0.priority >= 2 }.count) 个"
                )
            }
        }
    }

    private static func goalProgressRows(timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow] {
        let (_, _, days) = dayRange(timeRange)
        return await MainActor.run {
            let calendar = Calendar.current
            let goals = GoalRepository.shared.activeGoalsForAI(limit: 20)
            return days.compactMap { day in
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let progress = goals.compactMap { goal -> (Double, [String])? in
                    guard goal.createdAt < nextDay else { return nil }
                    let availableTasks = goal.sortedTasks.filter { $0.createdAt < nextDay }
                    guard !availableTasks.isEmpty else { return nil }
                    let completed = availableTasks.filter { task in
                        guard let completedAt = task.completedAt else { return false }
                        return completedAt < nextDay
                    }
                    return (
                        Double(completed.count) / Double(availableTasks.count) * 100,
                        [goal.id.uuidString] + completed.map { $0.id.uuidString }
                    )
                }
                guard !progress.isEmpty else { return nil }
                let value = progress.map(\.0).reduce(0, +) / Double(progress.count)
                let sourceIDs = progress.flatMap(\.1)
                return HoloQueryRow(
                    id: sourceIDs.joined(separator: ","),
                    occurredAt: day,
                    fields: ["date": .date(day), "value": .number(value)],
                    excerpt: "活跃目标关联任务平均完成进度 \(String(format: "%.1f", value))%"
                )
            }
        }
    }

    private static func dayRange(_ timeRange: HoloAgentTimeRange?) -> (start: Date, end: Date, days: [Date]) {
        let calendar = Calendar.current
        let end = timeRange?.end ?? Date()
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: end) ?? end)
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end, days.count < 366 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (start, end, days)
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
