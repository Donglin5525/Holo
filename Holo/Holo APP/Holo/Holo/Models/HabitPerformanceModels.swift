//
//  HabitPerformanceModels.swift
//  Holo
//
//  习惯表现语义模型：统一好习惯与坏习惯的统计口径
//

import Foundation

enum HabitPolarity: String, Codable, Equatable, Sendable {
    case positive
    case negative
}

enum HabitSuccessRule: String, Codable, Equatable, Sendable {
    case completeWhenDone
    case stayBelowTarget
    case abstain
}

struct HabitPerformanceSnapshot: Codable, Equatable, Sendable {
    let habitName: String
    let polarity: HabitPolarity
    let successRule: HabitSuccessRule
    let completionRate: Double
    let totalValue: Double?
    let targetValue: Double?
    let unit: String?
    let controlledDays: Int?
    let overLimitDays: Int?
    let completedDays: Int
    let totalDays: Int
}

enum HabitPerformanceEvaluator {
    static func evaluate(
        habitName: String,
        isBadHabit: Bool,
        isNumericType: Bool,
        totalDays: Int,
        completedCheckInDays: Int,
        dailyNumericValues: [Double],
        targetValue: Double?,
        unit: String?
    ) -> HabitPerformanceSnapshot {
        let dayCount = max(totalDays, 0)
        let polarity: HabitPolarity = isBadHabit ? .negative : .positive
        let totalValue = isNumericType ? dailyNumericValues.reduce(0, +) : nil

        if isBadHabit {
            if isNumericType, let targetValue {
                let overLimitDays = dailyNumericValues.filter { $0 > targetValue }.count
                let controlledDays = max(dayCount - overLimitDays, 0)
                return HabitPerformanceSnapshot(
                    habitName: habitName,
                    polarity: polarity,
                    successRule: .stayBelowTarget,
                    completionRate: rate(completed: controlledDays, total: dayCount),
                    totalValue: totalValue,
                    targetValue: targetValue,
                    unit: unit,
                    controlledDays: controlledDays,
                    overLimitDays: overLimitDays,
                    completedDays: controlledDays,
                    totalDays: dayCount
                )
            }

            let controlledDays = max(dayCount - completedCheckInDays, 0)
            return HabitPerformanceSnapshot(
                habitName: habitName,
                polarity: polarity,
                successRule: .abstain,
                completionRate: rate(completed: controlledDays, total: dayCount),
                totalValue: totalValue,
                targetValue: targetValue,
                unit: unit,
                controlledDays: controlledDays,
                overLimitDays: completedCheckInDays,
                completedDays: controlledDays,
                totalDays: dayCount
            )
        }

        let completedDays = isNumericType ? min(dailyNumericValues.count, dayCount) : completedCheckInDays
        return HabitPerformanceSnapshot(
            habitName: habitName,
            polarity: polarity,
            successRule: .completeWhenDone,
            completionRate: rate(completed: completedDays, total: dayCount),
            totalValue: totalValue,
            targetValue: targetValue,
            unit: unit,
            controlledDays: nil,
            overLimitDays: nil,
            completedDays: completedDays,
            totalDays: dayCount
        )
    }

    private static func rate(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}
