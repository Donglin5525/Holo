//
//  WeeklyReviewAggregator.swift
//  Holo
//
//  每周回顾数据聚合（2026-11-07 东林拍板 · 一期最小闭环）
//
//  - 纯本地聚合，全部走现有 Repository 的半开区间查询，零 CloudKit 新实体
//  - 四项足迹：记账（统计口径，含识图入账流水）/ 想法 / 完成任务 / 习惯打卡天数
//  - 对比口径 = 同期比（上周同一时刻 vs 现在），首周（上周同期无任何记录）不显示对比
//

import Foundation
import CoreData

// MARK: - 数据模型

/// 周回顾快照：一个时刻的四项足迹 + 上周同期对照
struct WeeklyReviewSnapshot: Equatable {
    /// 一个统计周期（半开区间）内四项足迹的计数
    struct PeriodCounts: Equatable {
        let transactionCount: Int    // 记账笔数（统计口径，识图入账即流水、天然并入）
        let thoughtCount: Int        // 想法条数
        let completedTaskCount: Int  // 完成任务数
        let habitDays: Int           // 习惯打卡天数（completed 记录按天去重）

        /// 记录总量口径（东林拍板）：记账 + 想法 + 任务；打卡天数不是记录，不计入
        var recordTotal: Int { transactionCount + thoughtCount + completedTaskCount }
        var hasAnyActivity: Bool {
            transactionCount > 0 || thoughtCount > 0 || completedTaskCount > 0 || habitDays > 0
        }
    }

    let weekStart: Date       // 本周一 00:00
    let referenceDate: Date   // 快照生成时刻（区间右端点）
    let current: PeriodCounts
    /// 上周同期（上周一 ~ 上周同一时刻）；上周同期完全无记录时为 nil（首周形态）
    let previous: PeriodCounts?
}

// MARK: - 周区间纯函数（可单测）

enum WeeklyReviewMath {
    /// date 所在周的周一 00:00。项目口径周一 = weekday 2；date 恰为周一时返回当天零点。
    static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)  // 1=周日 2=周一 … 7=周六
        let offset = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// 同期比区间对（东林拍板）：current = [本周一, now)，previous = [上周一, now − 7天)。
    /// 周四查看即 4 天比 4 天，自然避免「本周未过完 vs 上周整周」的假性落后。
    static func comparisonRanges(
        now: Date,
        calendar: Calendar
    ) -> (current: DateInterval, previous: DateInterval) {
        let currentStart = weekStart(containing: now, calendar: calendar)
        let previousStart = calendar.date(byAdding: .day, value: -7, to: currentStart) ?? currentStart
        let previousEnd = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        return (
            current: DateInterval(start: currentStart, end: now),
            previous: DateInterval(start: previousStart, end: previousEnd)
        )
    }
}

// MARK: - 聚合器

@MainActor
final class WeeklyReviewAggregator {
    static let shared = WeeklyReviewAggregator()

    private let finance: FinanceRepository
    private let thoughts: ThoughtRepository
    private let todos: TodoRepository
    private let habits: HabitRepository

    init(
        finance: FinanceRepository = .shared,
        thoughts: ThoughtRepository = ThoughtRepository(),
        todos: TodoRepository = .shared,
        habits: HabitRepository = HabitRepository.shared
    ) {
        self.finance = finance
        self.thoughts = thoughts
        self.todos = todos
        self.habits = habits
    }

    /// 生成周回顾快照。now 仅作区间右端点与首周判定基准，同一周内任意时刻结论一致。
    func makeSnapshot(now: Date = Date(), calendar: Calendar = .current) -> WeeklyReviewSnapshot {
        let ranges = WeeklyReviewMath.comparisonRanges(now: now, calendar: calendar)
        let current = countPeriod(ranges.current, calendar: calendar)
        let previousCounts = countPeriod(ranges.previous, calendar: calendar)
        return WeeklyReviewSnapshot(
            weekStart: ranges.current.start,
            referenceDate: now,
            current: current,
            previous: previousCounts.hasAnyActivity ? previousCounts : nil
        )
    }

    private func countPeriod(
        _ range: DateInterval,
        calendar: Calendar
    ) -> WeeklyReviewSnapshot.PeriodCounts {
        let transactionCount = finance.getStatisticsTransactionCount(from: range.start, to: range.end)
        let thoughtCount = (try? thoughts.fetchThoughts(from: range.start, to: range.end))?.count ?? 0
        let completedTaskCount = todos.getTasks(completedFrom: range.start, completedTo: range.end).count
        let completedHabitRecords = habits.getRecords(from: range.start, to: range.end)
            .filter(\.isCompleted)
        let habitDays = Set(completedHabitRecords.map { calendar.startOfDay(for: $0.date) }).count
        return WeeklyReviewSnapshot.PeriodCounts(
            transactionCount: transactionCount,
            thoughtCount: thoughtCount,
            completedTaskCount: completedTaskCount,
            habitDays: habitDays
        )
    }
}
