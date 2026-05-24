//
//  TodayStateResolver.swift
//  Holo
//
//  今日状态解析：根据数据覆盖度生成状态摘要或引导
//

import Foundation

enum TodayStateResolver {

    struct TodayStateResult: Equatable {
        let summary: String
        let coverageLevel: HoloMemoryCoverageLevel
        let sourceLabels: [String]
        let shouldGuide: Bool
    }

    /// 根据 UserContext 和数据覆盖度生成今日状态
    static func resolve(context: UserContext, coverage: HoloMemoryDataCoverage) -> TodayStateResult {
        switch coverage.level {
        case .rich:
            return resolveRichState(context: context, coverage: coverage)
        case .partial:
            return resolvePartialState(context: context, coverage: coverage)
        case .empty:
            return TodayStateResult(
                summary: "你还没有开始记录数据。试试记一笔消费、打卡一个习惯，或创建一个任务，Holo 就能帮你分析今天的整体状态了。",
                coverageLevel: .empty,
                sourceLabels: [],
                shouldGuide: true
            )
        }
    }

    // MARK: - Private

    private static func resolveRichState(context: UserContext, coverage: HoloMemoryDataCoverage) -> TodayStateResult {
        var parts: [String] = []
        var labels: [String] = []

        // 今日消费
        if !context.transactions.todayExpense.isEmpty {
            parts.append("今日消费 \(context.transactions.todayExpense)")
            labels.append("今日消费")
        }

        // 今日任务
        if context.tasks.todayTotal > 0 {
            let completed = context.tasks.todayCompleted
            let total = context.tasks.todayTotal
            parts.append("任务 \(completed)/\(total)")
            labels.append("今日任务")
        }

        // 今日习惯
        if context.habits.todayTotal > 0 {
            let completed = context.habits.todayCompleted
            let total = context.habits.todayTotal
            parts.append("习惯 \(completed)/\(total)")
            labels.append("今日习惯")
        }

        // 逾期任务
        if context.tasks.overdueCount > 0 {
            parts.append("\(context.tasks.overdueCount) 个任务逾期")
        }

        // 目标
        if let goalContext = context.goalContext, !goalContext.isEmpty {
            labels.append("进行中目标")
        }

        let summary = "今天的状态：\(parts.joined(separator: "，"))。"

        return TodayStateResult(
            summary: summary,
            coverageLevel: .rich,
            sourceLabels: labels,
            shouldGuide: false
        )
    }

    private static func resolvePartialState(context: UserContext, coverage: HoloMemoryDataCoverage) -> TodayStateResult {
        var parts: [String] = []
        var labels: [String] = []

        if context.tasks.todayTotal > 0 {
            parts.append("任务 \(context.tasks.todayCompleted)/\(context.tasks.todayTotal)")
            labels.append("今日任务")
        }

        if context.habits.todayTotal > 0 {
            parts.append("习惯 \(context.habits.todayCompleted)/\(context.habits.todayTotal)")
            labels.append("今日习惯")
        }

        if !context.transactions.recentTransactions.isEmpty {
            labels.append("近期消费")
        }

        if context.habits.totalActive > 0 {
            labels.append("活跃习惯")
        }

        let summary: String
        if parts.isEmpty {
            summary = "今天暂无新数据，但 Holo 已记录你的一些历史信息。参考范围有限，建议多记录一些数据以获得更精准的分析。"
        } else {
            summary = "今天的状态：\(parts.joined(separator: "，"))。数据还不完整，持续记录会让分析更准确。"
        }

        return TodayStateResult(
            summary: summary,
            coverageLevel: .partial,
            sourceLabels: labels,
            shouldGuide: false
        )
    }
}
