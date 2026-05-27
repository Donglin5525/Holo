//
//  DataCoverageEvaluator.swift
//  Holo
//
//  评估用户数据覆盖度：rich / partial / empty
//

import Foundation

enum DataCoverageEvaluator {

    struct SourceAvailability: Equatable {
        let source: HoloMemorySource
        let hasRecentData: Bool
        let hasHistoricalData: Bool
    }

    /// 根据各数据源可用性判断覆盖度等级
    static func evaluate(sources: [SourceAvailability]) -> HoloMemoryDataCoverage {
        let available = sources.filter { $0.hasRecentData || $0.hasHistoricalData }
        let recentCore = available.filter { $0.hasRecentData && isCoreSource($0.source) }
        let historicalCore = available.filter { $0.hasHistoricalData && isCoreSource($0.source) }

        let availableSourceList = available.map(\.source)
        let missingSourceList = HoloMemorySource.allCases.filter { source in
            !available.contains(where: { $0.source == source })
        }

        // rich: 至少 2 个核心数据源有近 7 天数据，或今日有明确任务/习惯/目标
        if recentCore.count >= 2 {
            return HoloMemoryDataCoverage(
                level: .rich,
                availableSources: availableSourceList,
                missingSources: missingSourceList,
                reason: "数据充足，共 \(available.count) 个来源可用"
            )
        }

        // partial: 至少 1 个数据源有近 30 天数据
        if historicalCore.count >= 1 || available.count >= 1 {
            return HoloMemoryDataCoverage(
                level: .partial,
                availableSources: availableSourceList,
                missingSources: missingSourceList,
                reason: "部分数据可用，共 \(available.count) 个来源"
            )
        }

        // empty: 无任务、无习惯、无记录、无目标
        return HoloMemoryDataCoverage(
            level: .empty,
            availableSources: [],
            missingSources: HoloMemorySource.allCases,
            reason: "暂无足够数据"
        )
    }

    /// 从 UserContext 直接提取数据源可用性
    static func evaluate(from context: UserContext) -> HoloMemoryDataCoverage {
        var sources: [SourceAvailability] = []

        // 财务
        let hasRecentExpense = !context.transactions.todayExpense.isEmpty
            || !context.transactions.recentTransactions.isEmpty
        sources.append(SourceAvailability(
            source: .finance,
            hasRecentData: hasRecentExpense,
            hasHistoricalData: hasRecentExpense
        ))

        // 习惯
        let hasHabits = context.habits.totalActive > 0
            || !context.habits.recentCheckIns.isEmpty
        sources.append(SourceAvailability(
            source: .habits,
            hasRecentData: hasHabits,
            hasHistoricalData: hasHabits
        ))

        // 任务
        let hasTasks = context.tasks.todayTotal > 0
            || !context.tasks.recentTasks.isEmpty
            || !context.tasks.activeTaskSummaries.isEmpty
        sources.append(SourceAvailability(
            source: .tasks,
            hasRecentData: hasTasks,
            hasHistoricalData: hasTasks
        ))

        // 观点
        let hasThoughts = !context.thoughts.recentThoughts.isEmpty
            || context.thoughts.totalThoughts > 0
        sources.append(SourceAvailability(
            source: .thoughts,
            hasRecentData: hasThoughts,
            hasHistoricalData: hasThoughts
        ))

        // 目标
        let hasGoals = context.goalContext != nil && !context.goalContext!.isEmpty
        sources.append(SourceAvailability(
            source: .goals,
            hasRecentData: hasGoals,
            hasHistoricalData: hasGoals
        ))

        // 档案
        let hasProfile = context.profileContext != nil && !context.profileContext!.isEmpty
        sources.append(SourceAvailability(
            source: .profile,
            hasRecentData: hasProfile,
            hasHistoricalData: hasProfile
        ))

        return evaluate(sources: sources)
    }

    private static func isCoreSource(_ source: HoloMemorySource) -> Bool {
        switch source {
        case .finance, .tasks, .habits, .goals, .thoughts:
            return true
        case .health, .profile, .conversation, .memoryInsight:
            return false
        }
    }
}
