//
//  HoloMemorySnapshotBuilder.swift
//  Holo
//
//  兼容旧能力启动台的即时上下文快照；不再维护独立“短期记忆”来源。
//

import Foundation

enum HoloMemorySnapshotBuilder {

    /// 构建即时上下文快照。档案、业务数据和长期记忆都复用各自唯一真相源，
    /// 此结构只做单次组装，不产生或保存第二套记忆。
    @MainActor
    static func build(window: HoloMemoryWindow = .today, purpose: HoloAICapabilityID? = nil) async -> HoloShortTermMemorySnapshot {
        let userContext = await UserContextBuilder.shared.buildContext()
        let coverage = DataCoverageEvaluator.evaluate(from: userContext)
        let relevantMemorySummary: HoloMemoryPromptSummary?
        if HoloAIFeatureFlags.memorySummaryInjectionEnabled {
            if let purpose {
                relevantMemorySummary = await HoloMemorySummaryProvider.selectRelevantSummary(
                    purpose: purpose
                )
            } else {
                relevantMemorySummary = userContext.memorySummary
            }
        } else {
            relevantMemorySummary = nil
        }

        var sourceSummaries: [HoloMemorySourceSummary] = []
        var signals: [HoloRecentSignal] = []

        // 任务来源
        if userContext.tasks.dueToday > 0 || userContext.tasks.completedToday > 0 || !userContext.tasks.recentTasks.isEmpty {
            sourceSummaries.append(HoloMemorySourceSummary(
                source: .tasks,
                count: userContext.tasks.dueToday,
                latestAt: nil
            ))
        }

        // 习惯来源
        if userContext.habits.totalActive > 0 || !userContext.habits.recentCheckIns.isEmpty {
            sourceSummaries.append(HoloMemorySourceSummary(
                source: .habits,
                count: userContext.habits.todayTotal,
                latestAt: nil
            ))

            if userContext.habits.todayTotal > 0 {
                signals.append(HoloRecentSignal(
                    id: UUID().uuidString,
                    source: .habits,
                    title: "今日习惯",
                    detail: "完成 \(userContext.habits.todayCompleted)/\(userContext.habits.todayTotal)",
                    occurredAt: nil
                ))
            }
        }

        // 财务来源
        if !userContext.transactions.todayExpense.isEmpty || !userContext.transactions.recentTransactions.isEmpty {
            sourceSummaries.append(HoloMemorySourceSummary(
                source: .finance,
                count: userContext.transactions.recentTransactions.count,
                latestAt: nil
            ))

            if !userContext.transactions.todayExpense.isEmpty {
                signals.append(HoloRecentSignal(
                    id: UUID().uuidString,
                    source: .finance,
                    title: "今日消费",
                    detail: userContext.transactions.todayExpense,
                    occurredAt: nil
                ))
            }
        }

        // 观点来源
        if userContext.thoughts.totalThoughts > 0 {
            sourceSummaries.append(HoloMemorySourceSummary(
                source: .thoughts,
                count: userContext.thoughts.totalThoughts,
                latestAt: nil
            ))
        }

        return HoloShortTermMemorySnapshot(
            generatedAt: Date(),
            window: window,
            dataCoverage: coverage,
            sourceSummary: sourceSummaries,
            recentSignals: signals,
            activeGoalSummary: userContext.goalContext,
            recentConversationIntent: nil,
            relevantLongTermMemorySummary: relevantMemorySummary
        )
    }
}
