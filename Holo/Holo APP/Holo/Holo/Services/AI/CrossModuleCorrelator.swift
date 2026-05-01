//
//  CrossModuleCorrelator.swift
//  Holo
//
//  跨模块关联检测
//  纯规则引擎，接收增强后的四维度上下文，输出关联观察列表
//

import Foundation

struct CrossModuleCorrelator {

    /// 检测已知跨模块关联模式
    static func detect(
        finance: MemoryInsightFinanceContext,
        habits: MemoryInsightHabitContext,
        tasks: MemoryInsightTaskContext,
        thoughts: MemoryInsightThoughtContext
    ) -> [CrossModuleCorrelation] {
        var results: [CrossModuleCorrelation] = []

        if let c = detectHabitFinanceCorrelation(finance: finance, habits: habits) {
            results.append(c)
        }
        if let c = detectTaskFinanceCorrelation(finance: finance, tasks: tasks) {
            results.append(c)
        }
        if let c = detectThoughtHabitCorrelation(habits: habits, thoughts: thoughts) {
            results.append(c)
        }
        if let c = detectTaskHabitCorrelation(tasks: tasks, habits: habits) {
            results.append(c)
        }

        return results
    }

    // MARK: - 习惯 ↔ 财务

    private static func detectHabitFinanceCorrelation(
        finance: MemoryInsightFinanceContext,
        habits: MemoryInsightHabitContext
    ) -> CrossModuleCorrelation? {
        // 最低样本量
        guard habits.activeHabitCount >= 3 else { return nil }
        let foodCategories = ["餐饮", "餐饮/早餐", "餐饮/午餐", "餐饮/晚餐", "餐饮/外卖"]
        let foodAmount = finance.topCategories
            .filter { foodCategories.contains($0.categoryName) || $0.categoryName.hasPrefix("餐饮") }
            .reduce(0) { $0 + $1.amount }
        guard foodAmount > 0, finance.totalExpense > 0 else { return nil }

        // 习惯完成率变化
        guard let currentRate = habits.averageCompletionRate else { return nil }
        let previousRate: Double = habits.activeHabitCount > 0
            ? Double(habits.previousPeriodCompletedRecordCount) / Double(habits.activeHabitCount) * 100
            : 0
        let rateDrop = previousRate - currentRate

        // 餐饮占比变化
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
            summary: "习惯完成率降 \(Int(rateDrop))%，餐饮占比升 \(Int(foodRatioRise))pp"
        )
    }

    // MARK: - 任务 ↔ 财务

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
            summary: "逾期率 \(Int(overdueRate))%，支出升 \(Int(expenseRise))%"
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
            summary: "负面心情 \(Int(negativeRatio))%，习惯完成率降 \(Int(rateDrop))%"
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

        // 同向变化：两者都低（低于 50%）或两者都高（高于 70%）
        let bothLow = taskRate < 50 && habitRate < 50
        let bothHigh = taskRate > 70 && habitRate > 70
        guard bothLow || bothHigh else { return nil }

        let delta = abs(taskRate - habitRate)
        guard delta < 30 else { return nil } // 差距不超过 30pp 才算正相关

        let signalStrength = bothHigh
            ? min(1.0, (taskRate + habitRate) / 200.0)
            : min(1.0, (100 - taskRate + 100 - habitRate) / 200.0)

        let direction = bothHigh ? "都表现良好" : "同时偏低"
        return CrossModuleCorrelation(
            modulePair: [.task, .habit],
            observation: "任务完成率和习惯完成率\(direction)",
            signalStrength: signalStrength,
            summary: "任务完成率 \(Int(taskRate))%，习惯完成率 \(Int(habitRate))%"
        )
    }
}
