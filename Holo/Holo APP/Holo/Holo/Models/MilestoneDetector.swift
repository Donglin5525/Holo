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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streakInfo = HabitRepository.shared.calculateStreakInfo(for: habit)
            let streakDays = streakInfo.value * habit.habitFrequency.periodDays
            let matchedThresholds = streakDaysThresholds.filter { streakDays >= $0 }

            for threshold in matchedThresholds {
                let milestone = MilestoneData(
                    title: "坚持\(habit.name) \(threshold) 天",
                    description: "已连续 \(streakInfo.displayText)不间断",
                    icon: "flame.fill",
                    milestoneType: .streakDays
                )

                // 达成日期 = 达到阈值的第 N 天（反推：今天往前推 streakDays - threshold 天）
                let daysAgo = streakDays - threshold
                let achievementDate = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                results.append((date: achievementDate, data: milestone))
            }
        }

        return results
    }

    // MARK: - Cumulative Count Milestone

    /// 检测累计记账笔数里程碑
    private static func detectCumulativeCount(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []
        let calendar = Calendar.current

        let countRequest = Transaction.fetchRequest()
        guard let count = (try? context.count(for: countRequest)) else { return results }

        let matchedThresholds = cumulativeCountThresholds.filter { count >= $0 }

        for threshold in matchedThresholds {
            // 查询第 N 笔交易的日期作为达成日期
            let dateRequest = Transaction.fetchRequest()
            dateRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            dateRequest.fetchOffset = threshold - 1
            dateRequest.fetchLimit = 1

            guard let nthTransaction = try? context.fetch(dateRequest).first else { continue }
            let transactionDate = nthTransaction.date

            let milestone = MilestoneData(
                title: "坚持记账 \(threshold) 笔",
                description: "累计记录 \(count) 笔交易",
                icon: "trophy.fill",
                milestoneType: .cumulativeCount
            )

            results.append((date: calendar.startOfDay(for: transactionDate), data: milestone))
        }

        return results
    }

    // MARK: - Habit Mastery Milestone

    /// 检测习惯掌握（单个习惯连续完成 >= 30 天）
    private static func detectHabitMastery(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: MilestoneData)] {
        var results: [(date: Date, data: MilestoneData)] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streakInfo = HabitRepository.shared.calculateStreakInfo(for: habit)
            let streakDays = streakInfo.value * habit.habitFrequency.periodDays
            guard streakDays >= habitMasteryThreshold, streakDays < 365 else { continue }

            let daysAgo = streakDays - habitMasteryThreshold
            let achievementDate = calendar.date(byAdding: .day, value: -daysAgo, to: today)!

            let milestone = MilestoneData(
                title: "掌握习惯「\(habit.name)」",
                description: "连续完成 \(streakInfo.displayText)，习惯已融入生活",
                icon: "star.fill",
                milestoneType: .habitMastery
            )

            results.append((date: achievementDate, data: milestone))
        }

        return results
    }
}
