//
//  MilestoneDetector.swift
//  Holo
//
//  里程碑检测算法
//  检测重大成就：连续打卡天数、累计记录数、习惯掌握
//

import Foundation
import CoreData

/// 里程碑检测器
struct MilestoneDetector {

    // MARK: - Thresholds

    /// 连续打卡里程碑阈值（天数）
    static let streakDaysThresholds = [30, 365]

    /// 累计记账笔数里程碑阈值
    static let cumulativeCountThresholds = [100, 500]

    /// 习惯掌握阈值（单个习惯连续完成天数）
    static let habitMasteryThreshold = 30

    // MARK: - Public API

    /// 检测所有里程碑
    /// - Parameter context: Core Data viewContext
    /// - Returns: 里程碑数据数组（附带触发日期）
    static func detect(context: NSManagedObjectContext) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []

        results.append(contentsOf: detectStreakDays(context: context))
        results.append(contentsOf: detectCumulativeCount(context: context))
        results.append(contentsOf: detectHabitMastery(context: context))

        return results
    }

    // MARK: - Streak Days Milestone

    /// 检测连续打卡 N 天里程碑
    private static func detectStreakDays(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []

        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streak = HabitRepository.shared.calculateStreak(for: habit)
            guard streakDaysThresholds.contains(streak) else { continue }

            let milestone = MilestoneData(
                title: "坚持\(habit.name) \(streak) 天",
                description: "连续 \(streak) 天不间断",
                icon: "flame.fill",
                milestoneType: .streakDays
            )

            // 触发日期 = 今天
            results.append((date: Calendar.current.startOfDay(for: Date()), data: milestone))
        }

        return results
    }

    // MARK: - Cumulative Count Milestone

    /// 检测累计记账笔数里程碑
    /// 使用 NSFetchRequest countResultType 避免加载全部数据
    private static func detectCumulativeCount(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []

        let request = Transaction.fetchRequest()
        request.resultType = .countResultType

        guard let count = (try? context.count(for: request)) else { return results }

        // 找到最大命中的阈值
        let matchedThresholds = cumulativeCountThresholds.filter { count >= $0 }
        guard let threshold = matchedThresholds.max() else { return results }

        let milestone = MilestoneData(
            title: "坚持记账 \(threshold) 笔",
            description: "累计记录 \(count) 笔交易",
            icon: "trophy.fill",
            milestoneType: .cumulativeCount
        )

        results.append((date: Calendar.current.startOfDay(for: Date()), data: milestone))

        return results
    }

    // MARK: - Habit Mastery Milestone

    /// 检测习惯掌握（单个习惯连续完成 >= 30 天）
    private static func detectHabitMastery(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []

        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streak = HabitRepository.shared.calculateStreak(for: habit)
            guard streak >= habitMasteryThreshold else { continue }

            // 只在恰好达到阈值时触发（或超过但未触发过更高里程碑）
            // 简化：当前 streak >= 30 且 < 365 时触发掌握里程碑
            guard streak < 365 else { continue }

            let milestone = MilestoneData(
                title: "掌握习惯「\(habit.name)」",
                description: "连续完成 \(streak) 天，习惯已融入生活",
                icon: "star.fill",
                milestoneType: .habitMastery
            )

            results.append((date: Calendar.current.startOfDay(for: Date()), data: milestone))
        }

        return results
    }
}
