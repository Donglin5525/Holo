//
//  HighlightDetector.swift
//  Holo
//
//  高亮检测算法
//  从已有模块数据中检测值得注意的事件，生成高亮节点
//
//  性能口径：消费异常/习惯全勤/重要任务三类检测为窗口级批量查询
//  （每类一次列查询 + 内存分组），不再逐日 N+1；streak 成就依赖
//  HabitRepository（@MainActor），保留主线程调用语义，量级 = 活跃习惯数。
//

import Foundation
import CoreData

/// 高亮检测器 — 复用已有 Repository 方法
struct HighlightDetector {

    // MARK: - Streak Achievement Thresholds

    /// 连续打卡成就阈值（天数）
    static let streakThresholds = [3, 7, 14, 21]

    /// 消费异常倍率（当日 > 7日均值 × 此值即触发）
    static let spendingAnomalyMultiplier: Double = 1.5

    // MARK: - Public API

    /// 为指定日期范围检测所有高亮（主线程调用方入口，签名与行为不变）
    /// - Parameters:
    ///   - dates: 需要检测的日期数组
    ///   - context: Core Data viewContext
    /// - Returns: 按日期分组的高亮数据 [Date: [HighlightData]]
    static func detect(
        for dates: [Date],
        context: NSManagedObjectContext
    ) -> [Date: [HighlightData]] {
        var results = detectBatch(for: dates, context: context)

        for highlight in detectStreakAchievements(context: context) {
            let dayStart = Calendar.current.startOfDay(for: highlight.date)
            results[dayStart, default: []].append(highlight.data)
        }

        return results
    }

    /// 批量检测（消费异常/习惯全勤/重要任务）：无主线程依赖，
    /// 可在任意 context（含后台）执行；查询次数与日期数无关。
    static func detectBatch(
        for dates: [Date],
        context: NSManagedObjectContext
    ) -> [Date: [HighlightData]] {
        let calendar = Calendar.current
        var results: [Date: [HighlightData]] = [:]

        for highlight in detectSpendingAnomalies(for: dates, context: context, calendar: calendar) {
            results[highlight.date, default: []].append(highlight.data)
        }

        for highlight in detectHabitPerfectDays(for: dates, context: context, calendar: calendar) {
            results[highlight.date, default: []].append(highlight.data)
        }

        for highlight in detectTaskCompletions(for: dates, context: context, calendar: calendar) {
            results[highlight.date, default: []].append(highlight.data)
        }

        return results
    }

    // MARK: - Streak Achievement Detection

    /// 检测习惯连续打卡成就（依赖 @MainActor HabitRepository，主线程执行）
    static func detectStreakAchievements(
        context: NSManagedObjectContext
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []
        let calendar = Calendar.current

        // 获取所有活跃习惯
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        guard let habits = try? context.fetch(habitRequest) else { return results }

        for habit in habits {
            let streakInfo = HabitRepository.shared.calculateStreakInfo(for: habit)
            guard streakThresholds.contains(streakInfo.value) else { continue }

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
                title: "连续\(habit.name) \(streakInfo.displayText)",
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
    /// 批量口径：一次拉 [min(dates)-7天, max(dates)] 支出两列（date/amount），
    /// 内存按日求和后逐日判定，替代原「每日期 2 次全对象查询」。
    private static func detectSpendingAnomalies(
        for dates: [Date],
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []
        guard let dayRange = detectedDayRange(of: dates, calendar: calendar) else { return results }
        guard let windowStart = calendar.date(byAdding: .day, value: -7, to: dayRange.min),
              let windowEnd = calendar.date(byAdding: .day, value: 1, to: dayRange.max) else {
            return results
        }

        let dayTotals = fetchExpenseDayTotals(
            from: windowStart, to: windowEnd, context: context, calendar: calendar
        )

        for date in dates {
            let dayStart = calendar.startOfDay(for: date)
            let dayExpense = dayTotals[dayStart] ?? 0
            guard dayExpense > 0 else { continue }

            // 7日均值（不含当日）
            var sevenDayTotal = 0.0
            for offset in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
                sevenDayTotal += dayTotals[day] ?? 0
            }
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
    /// 批量口径：一次拉窗口内已完成打卡两列（habitId/date）建集合，
    /// 内存逐日判全勤，替代原「每日期 × 每习惯一次查询」。
    /// 谓词口径与原实现一致（isCompleted == YES，不带 deletedAt 过滤）。
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

        guard let dayRange = detectedDayRange(of: dates, calendar: calendar) else { return results }
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: dayRange.max) else {
            return results
        }

        let recordRequest = NSFetchRequest<NSDictionary>(entityName: "HabitRecord")
        recordRequest.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND isCompleted == YES",
            dayRange.min as NSDate,
            windowEnd as NSDate
        )
        recordRequest.resultType = .dictionaryResultType
        recordRequest.propertiesToFetch = ["habitId", "date"]

        var completedDays = Set<String>()
        for row in (try? context.fetch(recordRequest)) ?? [] {
            guard let habitId = row["habitId"] as? UUID,
                  let date = row["date"] as? Date else { continue }
            completedDays.insert("\(habitId.uuidString)|\(calendar.startOfDay(for: date).timeIntervalSince1970)")
        }

        for date in dates {
            let dayStart = calendar.startOfDay(for: date)
            let dayKey = String(dayStart.timeIntervalSince1970)
            let allCompleted = habits.allSatisfy { habit in
                completedDays.contains("\(habit.id.uuidString)|\(dayKey)")
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
    /// 批量口径：一次拉窗口内三列（completedAt/title/priority），内存按日分组。
    /// 谓词口径与原实现一致（不带 deletedAt 过滤）。
    private static func detectTaskCompletions(
        for dates: [Date],
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [(date: Date, data: HighlightData)] {
        var results: [(date: Date, data: HighlightData)] = []

        guard let dayRange = detectedDayRange(of: dates, calendar: calendar) else { return results }
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: dayRange.max) else {
            return results
        }

        let request = NSFetchRequest<NSDictionary>(entityName: "TodoTask")
        request.predicate = NSPredicate(
            format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND priority >= %d",
            dayRange.min as NSDate,
            windowEnd as NSDate,
            TaskPriority.high.rawValue
        )
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["completedAt", "title", "priority"]

        let rows = (try? context.fetch(request)) ?? []

        for row in rows {
            guard let completedAt = row["completedAt"] as? Date,
                  let title = row["title"] as? String else { continue }

            let dayStart = calendar.startOfDay(for: completedAt)
            // 只为请求检测的日期产出（与原实现「按 dates 逐日查询」同边界）
            guard dates.contains(where: { calendar.isDate($0, inSameDayAs: dayStart) }) else { continue }

            let priority = (row["priority"] as? NSNumber)?.intValue ?? 0
            let highlight = HighlightData(
                category: .taskCompletion,
                title: "完成重要任务：\(title)",
                subtitle: priority == TaskPriority.urgent.rawValue ? "紧急任务" : nil,
                icon: "target",
                sourceModule: .task
            )
            results.append((date: dayStart, data: highlight))
        }

        return results
    }

    // MARK: - Helpers

    /// 检测日的[startOfDay]范围
    private static func detectedDayRange(of dates: [Date], calendar: Calendar) -> (min: Date, max: Date)? {
        let days = dates.map { calendar.startOfDay(for: $0) }
        guard let min = days.min(), let max = days.max() else { return nil }
        return (min, max)
    }

    /// 查询 [start, end) 支出总额按日分组（收支统计口径，排除对账调整流水）。
    /// 列查询（date/amount）不物化对象。
    private static func fetchExpenseDayTotals(
        from start: Date,
        to end: Date,
        context: NSManagedObjectContext,
        calendar: Calendar
    ) -> [Date: Double] {
        let request = NSFetchRequest<NSDictionary>(entityName: "Transaction")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "date >= %@ AND date < %@ AND type == %@",
                start as NSDate,
                end as NSDate,
                TransactionType.expense.rawValue
            ),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate()
        ])
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["date", "amount"]

        var totals: [Date: Double] = [:]
        for row in (try? context.fetch(request)) ?? [] {
            guard let date = row["date"] as? Date,
                  let amount = (row["amount"] as? NSNumber)?.doubleValue else { continue }
            totals[calendar.startOfDay(for: date), default: 0] += amount
        }
        return totals
    }
}
