//
//  AnalysisSummaryFormatter.swift
//  Holo
//
//  从 AnalysisContext 生成紧凑摘要
//

import Foundation

/// 分析查询紧凑摘要
struct AnalysisCompactSummary: Equatable {
    let icon: String
    let title: String
    let subtitle: String
    let summaryLine: String
}

/// 从 AnalysisContext 生成紧凑摘要
enum AnalysisSummaryFormatter {

    static func format(from context: AnalysisContext) -> AnalysisCompactSummary? {
        let periodLabel = resolvePeriodLabel(context)

        switch context.domain {
        case .finance:
            return formatFinance(context: context, periodLabel: periodLabel)
        case .habit:
            return formatHabit(context: context, periodLabel: periodLabel)
        case .task:
            return formatTask(context: context, periodLabel: periodLabel)
        case .thought:
            return formatThought(context: context, periodLabel: periodLabel)
        case .crossModule:
            return formatCrossModule(context: context, periodLabel: periodLabel)
        case .health:
            return formatHealth(context: context, periodLabel: periodLabel)
        case .goal:
            return formatGoal(context: context, periodLabel: periodLabel)
        }
    }

    // MARK: - Finance

    private static func formatFinance(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let finance = context.finance else { return nil }

        let totalExpense = NumberFormatter.compactCurrency(finance.totalExpense)
        let dailyAvg = NumberFormatter.compactCurrency(finance.averageDailyExpense)

        var changePart = ""
        if let previous = finance.previousPeriodExpense, previous > 0 {
            let diff = finance.totalExpense - previous
            let percent = Double(truncating: NSDecimalNumber(decimal: abs(diff) / previous * 100))
            if diff < 0 {
                changePart = " · 较上期 ↓\(String(format: "%.1f", percent))%"
            } else if diff > 0 {
                changePart = " · 较上期 ↑\(String(format: "%.1f", percent))%"
            }
        }

        return AnalysisCompactSummary(
            icon: "yensign",
            title: "账单分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "总支出 \(totalExpense) · 日均 \(dailyAvg)\(changePart)"
        )
    }

    // MARK: - Habit

    private static func formatHabit(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let habit = context.habit else { return nil }

        var parts: [String] = []
        if let rate = habit.averageCompletionRate {
            parts.append("达标率 \(String(format: "%.0f%%", rate * 100))")
        }
        parts.append("活跃 \(habit.activeHabitCount) 个")
        let maxStreak = habit.streaks.map(\.currentStreak).max() ?? 0
        if maxStreak > 0 {
            parts.append("最佳连续 \(maxStreak) 天")
        }

        return AnalysisCompactSummary(
            icon: "flame",
            title: "习惯分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: parts.joined(separator: " · ")
        )
    }

    // MARK: - Task

    private static func formatTask(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let task = context.task else { return nil }

        let ratePercent = String(format: "%.0f%%", task.completionRate * 100)

        return AnalysisCompactSummary(
            icon: "checklist",
            title: "任务分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "完成率 \(ratePercent) · 完成 \(task.completedCount)/\(task.totalCount) · 逾期 \(task.overdueCount)"
        )
    }

    // MARK: - Thought

    private static func formatThought(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let thought = context.thought else { return nil }

        return AnalysisCompactSummary(
            icon: "lightbulb",
            title: "想法分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "想法 \(thought.totalCount) 条 · 标签 \(thought.topTags.count) 个 · 心情分布 \(thought.moodDistribution.count) 类"
        )
    }

    // MARK: - CrossModule

    private static func formatCrossModule(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let cross = context.crossModule else { return nil }

        return AnalysisCompactSummary(
            icon: "chart.bar.xaxis",
            title: "综合分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "亮点 \(cross.highlights.count) 条 · 提醒 \(cross.warnings.count) 条"
        )
    }

    // MARK: - Health

    private static func formatHealth(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let health = context.health else { return nil }

        var parts: [String] = []
        if let score = health.overallBodyScore {
            parts.append("体表分 \(String(format: "%.0f", score))")
        }
        if let steps = health.steps, !steps.isDataFree {
            parts.append("日均 \(Int(steps.dailyAverage).formatted()) 步")
        }
        if let sleep = health.sleep, !sleep.isDataFree {
            parts.append("日均 \(String(format: "%.1f", sleep.dailyAverage))h 睡眠")
        }
        if !health.anomalyNotes.isEmpty {
            parts.append("\(health.anomalyNotes.count) 项提醒")
        }

        return AnalysisCompactSummary(
            icon: "heart.fill",
            title: "健康分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: parts.isEmpty ? "暂无数据" : parts.joined(separator: " · ")
        )
    }

    // MARK: - Goal

    private static func formatGoal(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let goal = context.goal else { return nil }

        var parts: [String] = []
        parts.append("活跃 \(goal.totalActiveGoals) 个")
        if goal.completedGoalsInPeriod > 0 {
            parts.append("完成 \(goal.completedGoalsInPeriod) 个")
        }
        if !goal.atRiskGoals.isEmpty {
            parts.append("\(goal.atRiskGoals.count) 个风险")
        }

        return AnalysisCompactSummary(
            icon: "target",
            title: "目标分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: parts.joined(separator: " · ")
        )
    }

    // MARK: - Period Label

    private static func resolvePeriodLabel(_ context: AnalysisContext) -> String {
        if !context.periodLabel.isEmpty {
            return context.periodLabel
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"

        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        guard let start = inputFormatter.date(from: context.startDate),
              let end = inputFormatter.date(from: context.endDate) else {
            return "\(context.startDate) — \(context.endDate)"
        }

        return "\(formatter.string(from: start)) — \(formatter.string(from: end))"
    }
}
