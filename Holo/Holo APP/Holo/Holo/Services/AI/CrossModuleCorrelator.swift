//
//  CrossModuleCorrelator.swift
//  Holo
//
//  跨模块关联检测
//  纯规则引擎，接收增强后的四维度上下文，输出关联观察列表
//

import Foundation

struct CrossModuleCorrelator {

    /// 禁止因果词列表
    private static let bannedWords = [
        "导致", "间接导致", "证明", "一定因为", "说明你就是",
        "自控力差", "焦虑症", "抑郁", "人格"
    ]

    /// 检测已知跨模块关联模式
    static func detect(
        finance: MemoryInsightFinanceContext,
        habits: MemoryInsightHabitContext,
        tasks: MemoryInsightTaskContext,
        thoughts: MemoryInsightThoughtContext,
        health: HealthInsightContext? = nil
    ) -> [CrossModuleCorrelation] {
        var results: [CrossModuleCorrelation] = []

        // 增强版：习惯断连 + 餐饮集中
        if let c = detectHabitFinanceCorrelation(finance: finance, habits: habits) {
            results.append(c)
        }
        // 增强版：任务堆积 + 消费上升
        if let c = detectTaskFinanceCorrelation(finance: finance, tasks: tasks) {
            results.append(c)
        }
        if let c = detectThoughtHabitCorrelation(habits: habits, thoughts: thoughts) {
            results.append(c)
        }
        if let c = detectTaskHabitCorrelation(tasks: tasks, habits: habits) {
            results.append(c)
        }
        if let c = detectEmotionSpendingCorrelation(finance: finance, thoughts: thoughts) {
            results.append(c)
        }
        // 增强版：工作日/周末跨模块模式
        if let c = detectWeekdayWeekendPattern(finance: finance) {
            results.append(c)
        }
        // 新增：重要任务完成 + 习惯恢复
        if let c = detectTaskHabitRecovery(tasks: tasks, habits: habits) {
            results.append(c)
        }
        // 新增：恢复迹象
        if let c = detectRecoverySignal(habits: habits, tasks: tasks) {
            results.append(c)
        }
        if let health {
            results.append(contentsOf: detectHealthCorrelations(health: health, habits: habits, tasks: tasks))
        }

        return deduplicateCorrelations(results)
    }

    // MARK: - 去重

    /// 同一周期内，同一 modulePair + evidenceDates + patternType 不应重复输出
    private static func deduplicateCorrelations(_ items: [CrossModuleCorrelation]) -> [CrossModuleCorrelation] {
        var seen: [String: CrossModuleCorrelation] = [:]

        for item in items {
            let pairKey = item.modulePair.map(\.rawValue).sorted().joined(separator: "+")
            let datesKey = item.evidenceDates.sorted().joined(separator: ",")
            let dedupeKey = "\(pairKey)|\(datesKey)|\(item.patternType ?? "")"

            if let existing = seen[dedupeKey] {
                // 优先级：恢复类 > 风险类，patternType 更具体者优先，signalStrength 更高者优先
                let isRecoveryNew = item.patternType?.contains("recovery") == true
                let isRecoveryOld = existing.patternType?.contains("recovery") == true
                let shouldReplace = isRecoveryNew && !isRecoveryOld
                    || item.patternType != nil && existing.patternType == nil
                    || item.signalStrength > existing.signalStrength

                if shouldReplace {
                    seen[dedupeKey] = item
                }
            } else {
                seen[dedupeKey] = item
            }
        }

        return Array(seen.values)
    }

    // MARK: - 习惯 ↔ 财务（增强版：连续断连 + 餐饮集中）

    private static func detectHabitFinanceCorrelation(
        finance: MemoryInsightFinanceContext,
        habits: MemoryInsightHabitContext
    ) -> CrossModuleCorrelation? {
        guard habits.activeHabitCount >= 3 else { return nil }
        let foodCategories = ["餐饮", "餐饮/早餐", "餐饮/午餐", "餐饮/晚餐", "餐饮/外卖"]
        let foodAmount = finance.topCategories
            .filter { foodCategories.contains($0.categoryName) || $0.categoryName.hasPrefix("餐饮") }
            .reduce(0) { $0 + $1.amount }
        guard foodAmount > 0, finance.totalExpense > 0 else { return nil }

        guard let currentRate = habits.averageCompletionRate else { return nil }
        let previousRate: Double = habits.activeHabitCount > 0
            ? Double(habits.previousPeriodCompletedRecordCount) / Double(habits.activeHabitCount) * 100
            : 0
        let rateDrop = previousRate - currentRate

        let currentFoodRatio = (foodAmount / finance.totalExpense as NSDecimalNumber).doubleValue * 100
        let previousFoodRatio: Double = finance.previousPeriodExpense > 0
            ? (foodAmount / finance.previousPeriodExpense as NSDecimalNumber).doubleValue * 100
            : 0
        let foodRatioRise = previousFoodRatio > 0 ? currentFoodRatio - previousFoodRatio : 0

        guard rateDrop > 10 || foodRatioRise > 5 else { return nil }

        let signalStrength = min(1.0, max(rateDrop, foodRatioRise) / 20.0)
        return CrossModuleCorrelation(
            modulePair: [.habit, .finance],
            observation: "本周习惯完成率下降，同时餐饮占比上升",
            signalStrength: signalStrength,
            summary: "习惯完成率降 \(Int(rateDrop))%，餐饮占比升 \(Int(foodRatioRise))pp",
            patternType: "habitBreak_foodSpike",
            evidenceDates: []
        )
    }

    // MARK: - 任务 ↔ 财务（增强版：任务堆积 + 消费上升）

    private static func detectTaskFinanceCorrelation(
        finance: MemoryInsightFinanceContext,
        tasks: MemoryInsightTaskContext
    ) -> CrossModuleCorrelation? {
        guard tasks.totalCount >= 5 else { return nil }

        let overdueRate = tasks.totalCount > 0
            ? Double(tasks.overdueCount) / Double(tasks.totalCount) * 100
            : 0
        guard overdueRate > 20 else { return nil }

        let expenseRise: Double = finance.previousPeriodExpense > 0
            ? ((finance.totalExpense - finance.previousPeriodExpense) / finance.previousPeriodExpense as NSDecimalNumber).doubleValue * 100
            : 0
        guard expenseRise > 15 else { return nil }

        let signalStrength = min(1.0, max(overdueRate - 20, expenseRise - 15) / 20.0)
        return CrossModuleCorrelation(
            modulePair: [.task, .finance],
            observation: "任务逾期率偏高，同时支出较上期上升",
            signalStrength: signalStrength,
            summary: "逾期率 \(Int(overdueRate))%，支出升 \(Int(expenseRise))%",
            patternType: "taskOverload_expenseRise",
            evidenceDates: []
        )
    }

    // MARK: - 想法 ↔ 习惯

    private static func detectThoughtHabitCorrelation(
        habits: MemoryInsightHabitContext,
        thoughts: MemoryInsightThoughtContext
    ) -> CrossModuleCorrelation? {
        guard thoughts.totalCount >= 5, habits.activeHabitCount >= 3 else { return nil }
        guard !thoughts.moodDistribution.isEmpty else { return nil }

        let negativeMoods = ["悲伤", "焦虑", "愤怒", "压抑", "沮丧", "烦躁", "难过"]
        let negativeCount = thoughts.moodDistribution
            .filter { negativeMoods.contains($0.key) }
            .reduce(0) { $0 + $1.value }
        let totalMoodCount = thoughts.moodDistribution.values.reduce(0, +)
        guard totalMoodCount > 0 else { return nil }
        let negativeRatio = Double(negativeCount) / Double(totalMoodCount) * 100
        guard negativeRatio > 40 else { return nil }

        guard let currentRate = habits.averageCompletionRate else { return nil }
        let previousRate: Double = habits.activeHabitCount > 0
            ? Double(habits.previousPeriodCompletedRecordCount) / Double(habits.activeHabitCount) * 100
            : 0
        let rateDrop = previousRate - currentRate
        guard rateDrop > 10 else { return nil }

        let signalStrength = min(1.0, negativeRatio / 60.0)
        return CrossModuleCorrelation(
            modulePair: [.thought, .habit],
            observation: "负面心情占比较高，同时习惯完成率下降",
            signalStrength: signalStrength,
            summary: "负面心情 \(Int(negativeRatio))%，习惯完成率降 \(Int(rateDrop))%",
            patternType: "negativeMood_habitDrop",
            evidenceDates: []
        )
    }

    // MARK: - 任务 ↔ 习惯

    private static func detectTaskHabitCorrelation(
        tasks: MemoryInsightTaskContext,
        habits: MemoryInsightHabitContext
    ) -> CrossModuleCorrelation? {
        guard tasks.totalCount >= 5, habits.activeHabitCount >= 3 else { return nil }

        guard let habitRate = habits.averageCompletionRate else { return nil }
        let taskRate = tasks.completionRate * 100

        let bothLow = taskRate < 50 && habitRate < 50
        let bothHigh = taskRate > 70 && habitRate > 70
        guard bothLow || bothHigh else { return nil }

        let delta = abs(taskRate - habitRate)
        guard delta < 30 else { return nil }

        let signalStrength = bothHigh
            ? min(1.0, (taskRate + habitRate) / 200.0)
            : min(1.0, (100 - taskRate + 100 - habitRate) / 200.0)

        let direction = bothHigh ? "都表现良好" : "同时偏低"
        return CrossModuleCorrelation(
            modulePair: [.task, .habit],
            observation: "任务完成率和习惯完成率\(direction)",
            signalStrength: signalStrength,
            summary: "任务完成率 \(Int(taskRate))%，习惯完成率 \(Int(habitRate))%",
            patternType: bothHigh ? "taskHabit_bothHigh" : "taskHabit_bothLow",
            evidenceDates: []
        )
    }

    // MARK: - 情绪 ↔ 消费

    private static func detectEmotionSpendingCorrelation(
        finance: MemoryInsightFinanceContext,
        thoughts: MemoryInsightThoughtContext
    ) -> CrossModuleCorrelation? {
        let sentiment = thoughts.thoughtSentimentSummary
        guard sentiment.source != "none",
              let negativeRatio = sentiment.negativeRatio,
              negativeRatio > 0.4 else { return nil }

        guard thoughts.totalCount >= 5 else { return nil }

        guard finance.previousPeriodExpense > 0 else { return nil }
        let expenseChange = ((finance.totalExpense - finance.previousPeriodExpense)
            / finance.previousPeriodExpense as NSDecimalNumber).doubleValue * 100
        guard expenseChange > 10 else { return nil }

        let signalStrength = min(1.0, max(negativeRatio, expenseChange / 50.0))
        return CrossModuleCorrelation(
            modulePair: [.thought, .finance],
            observation: "负面情绪占比较高，同时支出较上期上升",
            signalStrength: signalStrength,
            summary: "负面情绪 \(Int(negativeRatio * 100))%，支出升 \(Int(expenseChange))%",
            patternType: "negativeEmotion_expenseRise",
            evidenceDates: []
        )
    }

    // MARK: - 工作日/周末消费模式

    private static func detectWeekdayWeekendPattern(
        finance: MemoryInsightFinanceContext
    ) -> CrossModuleCorrelation? {
        guard let ww = finance.weekdayWeekendSpending else { return nil }

        let totalCount = ww.weekdayTransactionCount + ww.weekendTransactionCount
        guard totalCount >= 14 else { return nil }

        let weekdayAvg = ww.weekdayTransactionCount > 0
            ? (ww.weekdayExpense / Decimal(ww.weekdayTransactionCount) as NSDecimalNumber).doubleValue
            : 0
        let weekendAvg = ww.weekendTransactionCount > 0
            ? (ww.weekendExpense / Decimal(ww.weekendTransactionCount) as NSDecimalNumber).doubleValue
            : 0

        guard weekdayAvg > 0, weekendAvg > 0 else { return nil }

        let ratio = max(weekdayAvg, weekendAvg) / min(weekdayAvg, weekendAvg)
        guard ratio > 1.5 else { return nil }

        let higherSide = weekendAvg > weekdayAvg ? "周末" : "工作日"
        let signalStrength = min(1.0, (ratio - 1.0) / 1.0)
        return CrossModuleCorrelation(
            modulePair: [.finance, .finance],
            observation: "\(higherSide)日均消费明显高于另一侧",
            signalStrength: signalStrength,
            summary: "工作日日均 ¥\(Int(weekdayAvg))，周末日均 ¥\(Int(weekendAvg))",
            patternType: "weekdayWeekend_imbalance",
            evidenceDates: []
        )
    }

    // MARK: - 新增：重要任务完成 + 习惯恢复

    private static func detectTaskHabitRecovery(
        tasks: MemoryInsightTaskContext,
        habits: MemoryInsightHabitContext
    ) -> CrossModuleCorrelation? {
        // 有高优先级任务完成
        guard !tasks.importantCompletedTasks.isEmpty else { return nil }
        // 习惯完成率在回升（本期 > 上期）
        guard let currentRate = habits.averageCompletionRate, currentRate > 50 else { return nil }
        let previousRate: Double = habits.activeHabitCount > 0
            ? Double(habits.previousPeriodCompletedRecordCount) / Double(habits.activeHabitCount) * 100
            : 0
        guard currentRate > previousRate else { return nil }

        let rateRise = currentRate - previousRate
        let signalStrength = min(1.0, rateRise / 20.0)
        return CrossModuleCorrelation(
            modulePair: [.task, .habit],
            observation: "重要任务有推进，习惯也在恢复",
            signalStrength: signalStrength,
            summary: "完成 \(tasks.importantCompletedTasks.count) 个高优任务，习惯完成率升 \(Int(rateRise))%",
            patternType: "recovery_taskHabit",
            evidenceDates: []
        )
    }

    // MARK: - 新增：恢复迹象（优先展示）

    private static func detectRecoverySignal(
        habits: MemoryInsightHabitContext,
        tasks: MemoryInsightTaskContext
    ) -> CrossModuleCorrelation? {
        // 条件1：习惯从低完成率回升
        guard let currentRate = habits.averageCompletionRate else { return nil }
        let previousRate: Double = habits.activeHabitCount > 0
            ? Double(habits.previousPeriodCompletedRecordCount) / Double(habits.activeHabitCount) * 100
            : 0

        let habitRecovering = previousRate < 60 && currentRate > previousRate + 10
        // 条件2：逾期任务在被清理
        let taskClearing = tasks.overdueCount < tasks.completedCount && tasks.completedCount > 0

        guard habitRecovering || taskClearing else { return nil }

        let signalStrength = min(1.0, (currentRate - previousRate) / 30.0)
        return CrossModuleCorrelation(
            modulePair: [.habit, .task],
            observation: habitRecovering
                ? "习惯完成率在回升，之前的中断正在恢复"
                : "逾期任务在被清理，执行节奏在好转",
            signalStrength: max(0.5, signalStrength),
            summary: habitRecovering
                ? "习惯完成率从 \(Int(previousRate))% 回升到 \(Int(currentRate))%"
                : "完成 \(tasks.completedCount) 个任务，逾期 \(tasks.overdueCount) 个",
            patternType: "recovery_signal",
            evidenceDates: []
        )
    }

    // MARK: - 健康并发观察

    private static func detectHealthCorrelations(
        health: HealthInsightContext,
        habits: MemoryInsightHabitContext,
        tasks: MemoryInsightTaskContext
    ) -> [CrossModuleCorrelation] {
        var results: [CrossModuleCorrelation] = []

        let shortSleep = (health.sleepDurationHours ?? 99) > 0 && (health.sleepDurationHours ?? 99) < 6
        let lowSteps = (health.stepCount ?? 10_000) > 0 && (health.stepCount ?? 10_000) < 3_000
        let hasTaskPressure = tasks.overdueCount >= 1 || tasks.activeBacklogCount >= 3 || tasks.dueInPeriod >= 5
        let hasHabitBreak = habits.strugglingHabits.count >= 1 || (habits.averageCompletionRate ?? 100) < 60
        let hasRecoverySignal = tasks.completedCount > tasks.overdueCount && tasks.completedCount > 0

        if shortSleep && hasTaskPressure {
            results.append(CrossModuleCorrelation(
                modulePair: [.health, .task],
                observation: "休息偏少和任务压力在同一段时间出现",
                signalStrength: 0.65,
                summary: "睡眠少于 6h，任务也有堆积或逾期",
                patternType: "sleep_task_pressure",
                evidenceDates: []
            ))
        }

        if shortSleep && hasHabitBreak {
            results.append(CrossModuleCorrelation(
                modulePair: [.health, .habit],
                observation: "休息偏少时，习惯节奏也有中断",
                signalStrength: 0.6,
                summary: "睡眠少于 6h，习惯完成也偏弱",
                patternType: "sleep_habit_break",
                evidenceDates: []
            ))
        }

        if lowSteps && hasRecoverySignal {
            results.append(CrossModuleCorrelation(
                modulePair: [.health, .task],
                observation: "活动量偏低，但其他节奏有恢复迹象",
                signalStrength: 0.5,
                summary: "步数偏少，同时任务在推进",
                patternType: "low_activity_recovery",
                evidenceDates: []
            ))
        }

        return results.filter { correlation in
            !bannedWords.contains { word in
                correlation.observation.contains(word) || correlation.summary.contains(word)
            }
        }
    }
}
