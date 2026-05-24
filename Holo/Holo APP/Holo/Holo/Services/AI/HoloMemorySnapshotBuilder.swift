//
//  HoloMemorySnapshotBuilder.swift
//  Holo
//
//  单次流程内组装短期记忆快照，V1 不跨会话缓存
//

import Foundation

enum HoloMemorySnapshotBuilder {

    /// 构建短期记忆快照，内部复用 UserContextBuilder
    @MainActor
    static func build(window: HoloMemoryWindow = .today, purpose: HoloAICapabilityID? = nil) async -> HoloShortTermMemorySnapshot {
        let userContext = await UserContextBuilder.shared.buildContext()
        let coverage = DataCoverageEvaluator.evaluate(from: userContext)

        var sourceSummaries: [HoloMemorySourceSummary] = []
        var signals: [HoloRecentSignal] = []

        // 任务来源
        if userContext.tasks.todayTotal > 0 || !userContext.tasks.recentTasks.isEmpty {
            sourceSummaries.append(HoloMemorySourceSummary(
                source: .tasks,
                count: userContext.tasks.todayTotal,
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
            relevantLongTermMemorySummary: nil
        )
    }
}
