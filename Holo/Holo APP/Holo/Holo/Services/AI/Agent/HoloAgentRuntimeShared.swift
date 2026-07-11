//
//  HoloAgentRuntimeShared.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 5.1 接线：App 生命周期共享入口
//  为 HoloApp scenePhase（5.1）与后续 ChatViewModel（6.2）提供单一 runtime / 续跑管理器。
//  仅在 HoloAIFeatureFlags.agentRuntimeEnabled 开启时被访问；默认关，零副作用。
//

import Foundation

struct HoloDefaultCrossDomainDataSource: HoloCrossDomainDataSource, HoloDynamicRowDataSource {
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
        if source == "thought.daily" {
            let snapshot = await HoloDefaultThoughtDataSource().snapshot(timeRange: timeRange)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return snapshot.dailyCounts.compactMap { key, count in
                guard let date = formatter.date(from: key) else { return nil }
                return HoloQueryRow(
                    id: "thought-day-\(key)", occurredAt: date,
                    fields: ["date": .date(date), "value": .number(Double(count))],
                    excerpt: "想法 \(count) 条"
                )
            }
        }
        if source == "memory.entries" {
            let dataSource = await MainActor.run { HoloDefaultMemoryDataSource() }
            let longTerm = await dataSource.longTermConfirmed().map { ($0, "longTerm") }
            let episodic = await dataSource.episodicActive().map { ($0, "episodic") }
            return (longTerm + episodic).compactMap { record, kind in
                guard let date = record.occurredAt, Self.contains(date, in: timeRange) else { return nil }
                return HoloQueryRow(
                    id: record.id, occurredAt: date,
                    fields: ["date": .date(date), "kind": .text(kind), "title": .text(record.title), "summary": .text(record.summary), "value": .number(1)],
                    excerpt: "\(record.title)：\(record.summary)"
                )
            }
        }
        if source == "insight.records" {
            return await HoloDefaultInsightDataSource().recentInsights(limit: 50).compactMap { record in
                guard Self.contains(record.generatedAt, in: timeRange) else { return nil }
                return HoloQueryRow(
                    id: record.id.uuidString, occurredAt: record.generatedAt,
                    fields: [
                        "date": .date(record.generatedAt), "periodType": .text(record.periodType), "status": .text(record.status),
                        "title": .text(record.title), "summary": .text(record.summary), "value": .number(1)
                    ],
                    excerpt: "\(record.title)：\(record.summary)"
                )
            }
        }
        if source == "profile.items" {
            guard let profile = await HoloDefaultProfileDataSource().snapshot() else { return [] }
            let now = Date()
            let optionalItems: [(String, String?)] = [
                ("preferredName", profile.preferredName), ("language", profile.language), ("timezone", profile.timezone),
                ("city", profile.city), ("profession", profile.profession)
            ]
            var items: [(String, String)] = optionalItems.compactMap { key, value in value.map { (key, $0) } }
            items += profile.communicationStyle.map { ("communicationStyle", $0) }
            items += profile.currentFocus.map { ("currentFocus", $0) }
            items += profile.lifeContext.map { ("lifeContext", $0) }
            items += profile.healthHabitContext.map { ("healthHabitContext", $0) }
            items += profile.sensitiveBoundaries.map { ("sensitiveBoundary", $0) }
            return items.enumerated().map { index, item in
                HoloQueryRow(
                    id: "profile-\(item.0)-\(index)", occurredAt: now,
                    fields: ["date": .date(now), "category": .text(item.0), "valueText": .text(item.1), "value": .number(1)],
                    excerpt: "\(item.0)：\(item.1)"
                )
            }
        }
        if source == "conversation.metadata" {
            return await HoloDefaultConversationDataSource().recentRecords(limit: 200).compactMap { record in
                guard Self.contains(record.timestamp, in: timeRange) else { return nil }
                return HoloQueryRow(
                    id: "conversation-\(Int(record.timestamp.timeIntervalSince1970))-\(record.role)", occurredAt: record.timestamp,
                    fields: ["date": .date(record.timestamp), "role": .text(record.role), "intent": .text(record.intent ?? "unknown"), "value": .number(1)],
                    excerpt: "\(record.role) · \(record.intent ?? "unknown")"
                )
            }
        }
        return []
    }

    private static func contains(_ date: Date, in range: HoloAgentTimeRange?) -> Bool {
        guard let range else { return true }
        if let start = range.start, date < start { return false }
        if let end = range.end, date >= end { return false }
        return true
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
        let dynamicDataSource = HoloDefaultCrossDomainDataSource()
        let productionTools: [HoloDataTool] = [
            HoloDynamicToolDecorator(base: HoloMemoryTool(dataSource: HoloDefaultMemoryDataSource()), catalog: HoloAgentDynamicCatalogs.memory, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloHabitTool(dataSource: HoloDefaultHabitDataSource()), catalog: HoloAgentDynamicCatalogs.habit, dataSource: dynamicDataSource),
            HoloHealthTool(dataSource: HoloDefaultHealthDataSource()),
            HoloFinanceTool(dataSource: HoloDefaultFinanceDataSource()),
            HoloDynamicToolDecorator(base: HoloGoalTool(dataSource: HoloDefaultGoalDataSource()), catalog: HoloAgentDynamicCatalogs.goal, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloThoughtTool(dataSource: HoloDefaultThoughtDataSource()), catalog: HoloAgentDynamicCatalogs.thought, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloTaskTool(dataSource: HoloDefaultTaskDataSource()), catalog: HoloAgentDynamicCatalogs.task, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloProfileTool(dataSource: HoloDefaultProfileDataSource()), catalog: HoloAgentDynamicCatalogs.profile, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloConversationTool(dataSource: HoloDefaultConversationDataSource()), catalog: HoloAgentDynamicCatalogs.conversation, dataSource: dynamicDataSource),
            HoloDynamicToolDecorator(base: HoloInsightTool(dataSource: HoloDefaultInsightDataSource()), catalog: HoloAgentDynamicCatalogs.insight, dataSource: dynamicDataSource),
            HoloCrossDomainTool(dataSource: dynamicDataSource)
        ]
        assert(
            HoloAgentToolCoverage.missingToolNames(in: productionTools).isEmpty,
            "生产 Agent 工具注册不完整"
        )
        assert(
            HoloAgentToolCoverage.missingDynamicDatasets(in: productionTools).isEmpty,
            "生产 Agent 动态数据目录注册不完整"
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
