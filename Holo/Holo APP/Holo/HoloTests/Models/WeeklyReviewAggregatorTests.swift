//
//  WeeklyReviewAggregatorTests.swift
//  HoloTests
//
//  每周回顾聚合单测（2026-11-07 一期）：
//  1. 周区间纯函数：周一锚定 / 同期比区间恒差 7 天
//  2. 快照聚合：四项足迹计数、总量口径（打卡天数不计入）、首周判定、软删与取消打卡排除
//  3. 同期比裁剪：上周四 20:00 之后（now−7d 之外）的数据不进上周对照
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class WeeklyReviewAggregatorTests: XCTestCase {
    private var context: NSManagedObjectContext!
    private var aggregator: WeeklyReviewAggregator!

    /// 固定 UTC 公历日历：周一定义与断言不受本机时区/firstWeekday 影响
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 快照基准时刻：2026-11-05（周四）20:00 UTC，所在周 11.02（周一）– 11.08（周日）
    private var now: Date { utcDate(2026, 11, 5, 20, 0) }

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(
            context,
            ["Transaction", "Thought", "TodoTask", "HabitRecord"]
        )
        aggregator = WeeklyReviewAggregator(
            finance: FinanceRepository(context: context),
            thoughts: ThoughtRepository(context: context),
            todos: TodoRepository(context: context),
            habits: HabitRepository(context: context, observesRemoteChanges: false)
        )
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return utcCalendar.date(from: comps)!
    }

    // MARK: - 周区间纯函数

    func testWeekStartAnchorsToMonday() {
        let calendar = utcCalendar
        // 周三 → 本周一
        XCTAssertEqual(
            WeeklyReviewMath.weekStart(containing: utcDate(2026, 11, 4, 15, 0), calendar: calendar),
            utcDate(2026, 11, 2, 0, 0)
        )
        // 恰为周一（含凌晨零点前一刻的周日深夜）→ 当天/上周一
        XCTAssertEqual(
            WeeklyReviewMath.weekStart(containing: utcDate(2026, 11, 2, 0, 0), calendar: calendar),
            utcDate(2026, 11, 2, 0, 0)
        )
        // 周日 → 本周一
        XCTAssertEqual(
            WeeklyReviewMath.weekStart(containing: utcDate(2026, 11, 8, 23, 0), calendar: calendar),
            utcDate(2026, 11, 2, 0, 0)
        )
        // 上一个周日 → 上周一（跨月）
        XCTAssertEqual(
            WeeklyReviewMath.weekStart(containing: utcDate(2026, 11, 1, 10, 0), calendar: calendar),
            utcDate(2026, 10, 26, 0, 0)
        )
    }

    func testComparisonRangesAreSevenDaysApart() {
        let calendar = utcCalendar
        let ranges = WeeklyReviewMath.comparisonRanges(now: now, calendar: calendar)
        XCTAssertEqual(ranges.current.start, utcDate(2026, 11, 2, 0, 0))
        XCTAssertEqual(ranges.current.end, now)
        XCTAssertEqual(ranges.previous.start, utcDate(2026, 10, 26, 0, 0))
        XCTAssertEqual(ranges.previous.end, utcDate(2026, 10, 29, 20, 0))
        // 半开区间：上周对照恰好截到「上周同一时刻」
        XCTAssertEqual(
            calendar.date(byAdding: .day, value: -7, to: ranges.current.start),
            ranges.previous.start
        )
    }

    // MARK: - 快照聚合

    func testSnapshotAggregatesFourFootprints() throws {
        // 本周（11.02–11.05 20:00）：2 笔流水 + 1 想法 + 1 完成任务 + 同日 2 条打卡（= 1 天）
        try seedTransaction(date: utcDate(2026, 11, 3, 9, 0))
        try seedTransaction(date: utcDate(2026, 11, 5, 10, 0))
        try seedThought(date: utcDate(2026, 11, 4, 12, 0))
        try seedTask(completedAt: utcDate(2026, 11, 3, 18, 0))
        seedHabitRecord(date: utcDate(2026, 11, 3, 8, 0), isCompleted: true)
        seedHabitRecord(date: utcDate(2026, 11, 3, 21, 0), isCompleted: true)
        // 上周同期（10.26–10.29 20:00）：仅 1 笔流水
        try seedTransaction(date: utcDate(2026, 10, 29, 10, 0))

        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        XCTAssertEqual(snapshot.weekStart, utcDate(2026, 11, 2, 0, 0))
        XCTAssertEqual(snapshot.current.transactionCount, 2)
        XCTAssertEqual(snapshot.current.thoughtCount, 1)
        XCTAssertEqual(snapshot.current.completedTaskCount, 1)
        XCTAssertEqual(snapshot.current.habitDays, 1)
        // 总量口径：记账+想法+任务；打卡天数不计入
        XCTAssertEqual(snapshot.current.recordTotal, 4)
        XCTAssertEqual(snapshot.previous?.transactionCount, 1)
        XCTAssertEqual(snapshot.previous?.recordTotal, 1)
    }

    func testComparisonIsSamePeriodNotWholeLastWeek() throws {
        // 数据落在上周四 20:00 之后（上周同期区间之外、上周整周之内）：不得计入上周对照
        try seedTransaction(date: utcDate(2026, 10, 29, 21, 0))  // 上周四 21:00 > now−7d（20:00）
        try seedThought(date: utcDate(2026, 10, 30, 9, 0))       // 上周五

        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        // 上周同期区间内无任何记录 → 首周形态（previous 为 nil）
        XCTAssertNil(snapshot.previous)
        XCTAssertFalse(snapshot.current.hasAnyActivity)
    }

    func testFirstWeekWhenPreviousPeriodEmpty() throws {
        try seedThought(date: utcDate(2026, 11, 4, 12, 0))

        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        XCTAssertNil(snapshot.previous)
        XCTAssertEqual(snapshot.current.thoughtCount, 1)
    }

    func testEmptyWeekShowsNoActivity() {
        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        XCTAssertFalse(snapshot.current.hasAnyActivity)
        XCTAssertEqual(snapshot.current.recordTotal, 0)
        XCTAssertNil(snapshot.previous)
    }

    func testSoftDeletedAndUncompletedRecordsExcluded() throws {
        try seedTransaction(date: utcDate(2026, 11, 3, 9, 0), deletedAt: utcDate(2026, 11, 4, 0, 0))
        try seedThought(date: utcDate(2026, 11, 4, 12, 0), deletedAt: utcDate(2026, 11, 5, 0, 0))
        try seedTask(completedAt: utcDate(2026, 11, 3, 18, 0), deletedAt: utcDate(2026, 11, 5, 0, 0))
        seedHabitRecord(date: utcDate(2026, 11, 3, 8, 0), isCompleted: false)

        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        XCTAssertFalse(snapshot.current.hasAnyActivity)
    }

    func testHabitOnlyUserCountsDaysButNotRecordTotal() throws {
        // 东林拍板：只打卡用户主数字为 0（打卡天数在列表可见）
        seedHabitRecord(date: utcDate(2026, 11, 3, 8, 0), isCompleted: true)

        let snapshot = aggregator.makeSnapshot(now: now, calendar: utcCalendar)

        XCTAssertTrue(snapshot.current.hasAnyActivity)
        XCTAssertEqual(snapshot.current.habitDays, 1)
        XCTAssertEqual(snapshot.current.recordTotal, 0)
    }

    // MARK: - 造数

    private func seedTransaction(date: Date, deletedAt: Date? = nil) throws {
        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.date = date
        transaction.amount = 25 as NSDecimalNumber
        transaction.deletedAt = deletedAt
        try context.save()
    }

    private func seedThought(date: Date, deletedAt: Date? = nil) throws {
        let thought = Thought(context: context)
        thought.id = UUID()
        thought.createdAt = date
        thought.deletedAt = deletedAt
        thought.isArchived = false
        try context.save()
    }

    private func seedTask(completedAt: Date, deletedAt: Date? = nil) throws {
        let task = TodoTask(context: context)
        task.id = UUID()
        task.createdAt = completedAt
        task.completedAt = completedAt
        task.deletedAt = deletedAt
        task.archived = false
        try context.save()
    }

    private func seedHabitRecord(date: Date, isCompleted: Bool) {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = UUID()
        record.date = date
        record.createdAt = date
        record.isCompleted = isCompleted
        try? context.save()
    }
}
