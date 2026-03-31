//
//  HighlightDetector.swift
//  Holo
//
//  高亮检测算法
//  从已有模块数据中检测值得注意的事件，生成高亮节点
//

import Foundation
import CoreData

/// 高亮检测器 — 在主线程执行，复用已有 Repository 方法
struct HighlightDetector {

    // MARK: - Streak Achievement Thresholds

    /// 连续打卡成就阈值（天数）
    static let streakThresholds = [3, 7, 14, 21]

    // MARK: - Spending Anomaly

    /// 消费异常倍率（当日 > 7日均值 × 此值即触发）
    static let spendingAnomalyMultiplier: Double = 1.5

    // MARK: - Public API

    /// 为指定日期范围检测所有高亮
    /// - Parameters:
    ///   - dates: 需要检测的日期数组
    ///   - context: Core Data viewContext
    /// - Returns: 按日期分组的高亮数据 [Date: [HighlightData]]
    static func detect(
        for dates: [Date],
        context: NSManagedObjectContext
    ) -> [Date: [HighlightData]] {
        var results: [Date: [HighlightData]] = [:]

        let calendar = Calendar.current

        // 1. 连续打卡成就
        let streakHighlights = detectStreakAchievements(context: context, calendar: calendar)
        for highlight in streakHighlights {
            let dayStart = calendar.startOfDay(for: highlight.date)
            results[dayStart, default: []].append(highlight.data)
        }

        // 2. 消费异常
        let spendingHighlights = detectSpendingAnomalies(for: dates, context: context, calendar: calendar)
        for highlight in spendingHighlights {
            results[highlight.date, default: []].append(highlight.data)
        }

        // 3. 习惯全勤日
        let perfectHighlights = detectHabitPerfectDays(for: dates, context: context, calendar: calendar)
        for highlight in perfectHighlights {
            results[highlight.date, default: []].append(highlight.data)
        }

        // 4. 重要任务完成
        let taskHighlights = detectTaskCompletions(for: dates, context: context, calendar: calendar)
        for highlight in taskHighlights {
            results[highlight.date, default: []].append(highlight.data)
        }

        return results
    }

    // MARK: - Streak Achievement Detection

    /// 检测习惯连续打卡成就
    private static func detectStreakAchievements(
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []

        // 获取所有活跃习惯
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streak = HabitRepository.shared.calculateStreak(for: habit)
            guard streakThresholds.contains(streak) else { continue }

            // 成就日期 = streak 中最新一天（今天或昨天）
            let achievementDate: Date
            let todayCompleted = HabitRepository.shared.isTodayCompleted(for: habit)
            if todayCompleted {
                achievementDate = calendar.startOfDay(for: Date())
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) {
                achievementDate = calendar.startOfDay(for: yesterday)
            } else {
                continue
            }

            let highlight = HighlightData(
                category: .streakAchievement,
                title: "连续\(habit.name) \(streak)天",
                subtitle: "继续保持！",
                icon: "flame.fill",
                sourceModule: .habitRecord
            )

            results.append((date: achievementDate, data: highlight))
        }

        return results
    }

    // MARK: - Spending Anomaly Detection

    /// 检测消费异常（当日消费 > 7日日均 × 1.5）
    private static func detectSpendingAnomalies(
        for dates: [Date],
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []

        for date in dates {
            let dayStart = calendar.startOfDay(for: date)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            // 当日消费
            let dayExpense = fetchExpenseTotal(from: dayStart, to: dayEnd, context: context)
            guard dayExpense > 0 else { continue }

            // 7日均值（不含当日）
            guard let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: dayStart) else { continue }
            let sevenDayTotal = fetchExpenseTotal(from: sevenDaysAgo, to: dayStart, context: context)
            let dailyAverage = sevenDayTotal / 7.0

            // 需要至少有消费数据才比较
            guard dailyAverage > 0 else { continue }

            let ratio = dayExpense / dailyAverage
            if ratio >= spendingAnomalyMultiplier {
                let percentage = Int((ratio - 1.0) * 100)
                let highlight = HighlightData(
                    category: .spendingAnomaly,
                    title: "今日消费比日均高 \(percentage)%",
                    subtitle: String(format: "¥%.0f vs 日均¥%.0f", dayExpense, dailyAverage),
                    icon: "exclamationmark.triangle.fill",
                    sourceModule: .transaction
                )
                results.append((date: dayStart, data: highlight))
            }
        }

        return results
    }

    // MARK: - Habit Perfect Day Detection

    /// 检测习惯全勤日（当日所有习惯全部完成）
    private static func detectHabitPerfectDays(
        for dates: [Date],
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []

        // 获取所有活跃习惯
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }
        guard !habits.isEmpty else { return results }

        for date in dates {
            let dayStart = calendar.startOfDay(for: date)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            var allCompleted = true
            for habit in habits {
                let recordRequest = HabitRecord.fetchRequest()
                recordRequest.predicate = NSPredicate(
                    format: "habitId == %@ AND date >= %@ AND date < %@ AND isCompleted == YES",
                    habit.id as CVarArg,
                    dayStart as NSDate,
                    dayEnd as NSDate
                )
                recordRequest.fetchLimit = 1

                let hasRecord = ((try? context.fetch(recordRequest))?.count ?? 0) > 0
                if !hasRecord {
                    allCompleted = false
                    break
                }
            }

            if allCompleted {
                let highlight = HighlightData(
                    category: .habitPerfect,
                    title: "习惯全勤日",
                    subtitle: "\(habits.count) 个习惯全部完成",
                    icon: "sparkles",
                    sourceModule: .habitRecord
                )
                results.append((date: dayStart, data: highlight))
            }
        }

        return results
    }

    // MARK: - Task Completion Detection

    /// 检测重要任务完成（priority >= high）
    private static func detectTaskCompletions(
        for dates: [Date],
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []

        for date in dates {
            let dayStart = calendar.startOfDay(for: date)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(
                format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND priority >= %d",
                dayStart as NSDate,
                dayEnd as NSDate,
                TaskPriority.high.rawValue
            )

            guard let tasks = try? context.fetch(request) else { continue }

            for task in tasks {
                let highlight = HighlightData(
                    category: .taskCompletion,
                    title: "完成重要任务：\(task.title)",
                    subtitle: task.priority == TaskPriority.urgent.rawValue ? "紧急任务" : nil,
                    icon: "target",
                    sourceModule: .task
                )
                results.append((date: dayStart, data: highlight))
            }
        }

        return results
    }

    // MARK: - Helper

    /// 查询指定时间范围内的支出总额
    private static func fetchExpenseTotal(
        from startDate: Date,
        to endDate: Date,
        context: NSManagedObjectContext
    ) -> Double {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND type == %@",
            startDate as NSDate,
            endDate as NSDate,
            TransactionType.expense.rawValue
        )

        guard let transactions = try? context.fetch(request) else { return 0 }

        return transactions.reduce(0.0) { sum, t in
            sum + t.amount.doubleValue
        }
    }
}
