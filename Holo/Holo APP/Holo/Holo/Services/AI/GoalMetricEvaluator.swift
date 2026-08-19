//
//  GoalMetricEvaluator.swift
//  Holo
//
//  量化目标进度与预测评估（与 GoalProgressEvaluator 并列：
//  过程型走六档状态，量化型走「类型 × 数据源」矩阵的大数字口径）
//
//  单一事实来源原则：Goal 不存 currentValue，进度每次展示时从源实时计算。
//

import Foundation

/// 量化目标进度快照
struct GoalMetricProgress: Equatable {
    /// 累积型=当前累计值；达标型=最新记录值（无记录时=基线）
    let currentValue: Double
    /// 0~1。累积型=累计÷目标；达标型=|基线−当前|÷|基线−目标|（基线视角，不从 0 起）
    let progress: Double
    let isAchieved: Bool
    /// 进度 <10% 或速率不足时为 nil（低速段预测波动大，不输出避免误判打击用户）
    let forecast: GoalMetricForecast?
}

/// 预测结论：日均速率外推出的预计达成日 + 与截止日的比较
struct GoalMetricForecast: Equatable {
    let predictedDate: Date
    /// 有截止日期时才有结论：true=预计如期达成
    let meetsDeadline: Bool?
}

@MainActor
enum GoalMetricEvaluator {

    /// 入口：非量化目标或配置不完整返回 nil（调用方回落过程型展示）。
    /// habit 源习惯失效（被删/归档）同样返回 nil，由 isHabitSourceUnavailable 区分提示。
    static func evaluate(goal: Goal) -> GoalMetricProgress? {
        guard goal.isQuantitative,
              let target = goal.metricTargetValueDouble, target > 0 else { return nil }

        switch goal.metricSourceEnum {
        case .manual:
            return evaluateManual(goal: goal, target: target)
        case .habit:
            return evaluateHabit(goal: goal, target: target)
        case .ledger:
            return evaluateLedger(goal: goal, target: target)
        }
    }

    // MARK: - manual 源

    private static func evaluateManual(goal: Goal, target: Double) -> GoalMetricProgress? {
        switch goal.goalKindEnum {
        case .process:
            return nil
        case .cumulative:
            // 累积型：从累计起点对手动记录求和
            let start = goal.baselineDate ?? goal.createdAt
            let sum = GoalRepository.shared.getMetricLogs(for: goal)
                .filter { $0.date >= start }
                .reduce(0.0) { $0 + $1.value }
            return makeProgress(goal: goal, current: sum, target: target, baseline: nil, elapsedAnchor: start)
        case .target:
            // 达标型：取最新一条记录为当前水平，无记录时=基线
            guard let baseline = goal.baselineValueDouble, baseline != target else { return nil }
            let current = GoalRepository.shared.latestMetricLog(for: goal)?.value ?? baseline
            return makeProgress(goal: goal, current: current, target: target, baseline: baseline, elapsedAnchor: goal.baselineDate ?? goal.createdAt)
        }
    }

    // MARK: - habit 源

    /// habit 源的源习惯（活跃未归档才有效）；nil = 源失效（进度不可算，详情页提示重选）
    static func sourceHabit(for goal: Goal) -> Habit? {
        guard goal.metricSourceEnum == .habit, let habitId = goal.sourceHabitId else { return nil }
        guard let habit = HabitRepository.shared.findHabit(by: habitId), !habit.isArchived else { return nil }
        return habit
    }

    /// habit 源是否失效（源习惯被删除或归档）
    static func isHabitSourceUnavailable(goal: Goal) -> Bool {
        goal.isQuantitative && goal.metricSourceEnum == .habit && sourceHabit(for: goal) == nil
    }

    private static func evaluateHabit(goal: Goal, target: Double) -> GoalMetricProgress? {
        guard let habit = sourceHabit(for: goal) else { return nil }
        switch goal.goalKindEnum {
        case .process:
            return nil
        case .cumulative:
            // 累积型：源习惯按日聚合后从累计起点求和。
            // sum 口径习惯天然适配；latest 口径（测量类）做累积源时每日取最新值再加总，
            // 口径错配的提示在表单侧做行内提醒，这里不硬拦
            let start = goal.baselineDate ?? goal.createdAt
            let sum = HabitRepository.shared.getDailyAggregatedData(for: habit, dateRange: start...Date())
                .reduce(0.0) { $0 + $1.value }
            return makeProgress(goal: goal, current: sum, target: target, baseline: nil, elapsedAnchor: start)
        case .target:
            // 达标型：源习惯最新一条为当前水平，无记录时=基线
            guard let baseline = goal.baselineValueDouble, baseline != target else { return nil }
            let current = HabitRepository.shared.getLatestValue(for: habit) ?? baseline
            return makeProgress(goal: goal, current: current, target: target, baseline: baseline, elapsedAnchor: goal.baselineDate ?? goal.createdAt)
        }
    }

    // MARK: - ledger 源

    /// ledger 源只配累积型（存钱目标）：当前净结余 − 基线日净结余。
    /// 口径=全账本（未归档）期初+净流，与净资产页一致，含信用卡负债
    private static func evaluateLedger(goal: Goal, target: Double) -> GoalMetricProgress? {
        guard goal.goalKindEnum == .cumulative else { return nil }
        let finance = FinanceRepository.shared
        let start = goal.baselineDate ?? goal.createdAt
        let saved = finance.getCumulativeBalance(before: Date()) - finance.getCumulativeBalance(before: start)
        let current = NSDecimalNumber(decimal: saved).doubleValue
        return makeProgress(goal: goal, current: current, target: target, baseline: nil, elapsedAnchor: start)
    }

    // MARK: - 进度与预测

    private static func makeProgress(
        goal: Goal,
        current: Double,
        target: Double,
        baseline: Double?,
        elapsedAnchor: Date
    ) -> GoalMetricProgress {
        // 已变多少 / 共需变多少；达标型方向由基线与目标大小自动决定
        let moved: Double
        let total: Double
        if let baseline, baseline != target {
            total = abs(target - baseline)
            moved = max(0, target > baseline ? (current - baseline) : (baseline - current))
        } else {
            total = target
            moved = max(0, current)
        }
        let progress = total > 0 ? min(moved / total, 1) : 0
        let achieved = moved >= total

        return GoalMetricProgress(
            currentValue: current,
            progress: progress,
            isAchieved: achieved,
            forecast: makeForecast(goal: goal, moved: moved, total: total, elapsedAnchor: elapsedAnchor, achieved: achieved, progress: progress)
        )
    }

    /// 预测：日均速率外推预计达成日，与 deadline 比较出结论。
    /// 已达成、进度 <10%、速率为 0 时不输出。
    private static func makeForecast(
        goal: Goal,
        moved: Double,
        total: Double,
        elapsedAnchor: Date,
        achieved: Bool,
        progress: Double
    ) -> GoalMetricForecast? {
        guard !achieved, progress >= 0.1 else { return nil }
        let elapsedDays = max(1.0, Date().timeIntervalSince(elapsedAnchor) / 86400)
        let dailyRate = moved / elapsedDays
        guard dailyRate > 0 else { return nil }
        let remainingDays = (total - moved) / dailyRate
        let predictedDate = Date().addingTimeInterval(remainingDays * 86400)
        return GoalMetricForecast(
            predictedDate: predictedDate,
            meetsDeadline: goal.deadline.map { predictedDate <= $0 }
        )
    }

    // MARK: - 展示格式化

    /// 数值展示：整数不带小数点，小数保留一位（与 Habit.formatValue 同口径）
    static func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// 日期展示（如「11月2日」，预测与记录行共用）
    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
