//
//  TaskAnalyticsPeriodResolverTests.swift
//  HoloTests
//
//  统计周期解析边界测试（2026-10-06 任务重构方案 §7.2/§7.6/§7.7 / R40–R42/R47–R48）
//

import XCTest
@testable import Holo

final class TaskAnalyticsPeriodResolverTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    // MARK: - 周期边界

    func test_周界_周一为首() {
        // 2026-10-06 是周二；锚定它 → 周期 10-05（周一）至 10-12
        let bounds = TaskAnalyticsPeriodResolver.bounds(
            of: .week(anchorDay: makeDate(2026, 10, 6)), asOf: makeDate(2026, 10, 6, 15, 30), calendar: calendar
        )
        XCTAssertEqual(bounds.start, makeDate(2026, 10, 5))
        XCTAssertEqual(bounds.endExclusive, makeDate(2026, 10, 12))
    }

    func test_月界_年界() {
        let month = TaskAnalyticsPeriodResolver.bounds(
            of: .month(anchorDay: makeDate(2026, 10, 15)), asOf: makeDate(2026, 10, 6, 15, 30), calendar: calendar
        )
        XCTAssertEqual(month.start, makeDate(2026, 10, 1))
        XCTAssertEqual(month.endExclusive, makeDate(2026, 11, 1))

        let year = TaskAnalyticsPeriodResolver.bounds(
            of: .year(anchorDay: makeDate(2026, 3, 1)), asOf: makeDate(2026, 10, 6, 15, 30), calendar: calendar
        )
        XCTAssertEqual(year.start, makeDate(2026, 1, 1))
        XCTAssertEqual(year.endExclusive, makeDate(2027, 1, 1))
    }

    func test_自定义_含首尾自然日() {
        let bounds = TaskAnalyticsPeriodResolver.bounds(
            of: .custom(startDay: makeDate(2026, 9, 20), endDay: makeDate(2026, 9, 25)),
            asOf: makeDate(2026, 10, 6, 15, 30), calendar: calendar
        )
        XCTAssertEqual(bounds.start, makeDate(2026, 9, 20))
        XCTAssertEqual(bounds.endExclusive, makeDate(2026, 9, 26))
        XCTAssertFalse(bounds.isOngoing)
    }

    // MARK: - 前后切换

    func test_周前后切换() {
        let prev = TaskAnalyticsPeriodResolver.previous(of: .week(anchorDay: makeDate(2026, 10, 6)), calendar: calendar)
        if case .week(let anchor) = prev {
            XCTAssertEqual(calendar.startOfDay(for: anchor), makeDate(2026, 9, 29))
        } else {
            XCTFail("上一周期应为周")
        }
    }

    func test_下一周期门禁_不能进尚未开始的未来周期() {
        let now = makeDate(2026, 10, 6, 15, 30)
        // 当前周 → 下周（10-12 开始）尚未开始：禁用
        XCTAssertFalse(TaskAnalyticsPeriodResolver.nextAllowed(.week(anchorDay: makeDate(2026, 10, 6)), asOf: now, calendar: calendar))
        // 上周 → 本周：允许
        XCTAssertTrue(TaskAnalyticsPeriodResolver.nextAllowed(.week(anchorDay: makeDate(2026, 9, 29)), asOf: now, calendar: calendar))
    }

    func test_自定义下一等长窗口_完整结束晚于今天则禁用() {
        let now = makeDate(2026, 10, 6, 15, 30)
        // 今天 10-06 单日窗口：下一窗口 10-07..10-07 完整结束晚于今天 → 禁用
        XCTAssertFalse(TaskAnalyticsPeriodResolver.nextAllowed(.custom(startDay: makeDate(2026, 10, 6), endDay: makeDate(2026, 10, 6)), asOf: now, calendar: calendar))
        // 昨天单日窗口：下一窗口 = 今天（恰好今天结束，未越出今天）→ 允许，按同等已过窗口比较
        XCTAssertTrue(TaskAnalyticsPeriodResolver.nextAllowed(.custom(startDay: makeDate(2026, 10, 5), endDay: makeDate(2026, 10, 5)), asOf: now, calendar: calendar))
        // 前天单日窗口：下一窗口 = 昨天，已结束 → 允许
        XCTAssertTrue(TaskAnalyticsPeriodResolver.nextAllowed(.custom(startDay: makeDate(2026, 10, 4), endDay: makeDate(2026, 10, 4)), asOf: now, calendar: calendar))
    }

    // MARK: - 对比窗口

    func test_未结束周期_同等已过窗口比较() {
        // R47：现在周二 15:30 → 本周一 00:00 至周二 15:30 vs 上周一 00:00 至上周二 15:30
        let now = makeDate(2026, 10, 6, 15, 30)
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: .week(anchorDay: now), asOf: now, calendar: calendar)
        let window = TaskAnalyticsPeriodResolver.compareWindow(current: bounds, asOf: now, calendar: calendar)
        XCTAssertEqual(window.currentStart, makeDate(2026, 10, 5))
        XCTAssertEqual(window.currentEnd, makeDate(2026, 10, 6, 15, 30))
        XCTAssertEqual(window.previousStart, makeDate(2026, 9, 28))
        XCTAssertEqual(window.previousEnd, makeDate(2026, 9, 29, 15, 30))
        XCTAssertFalse(window.truncatedToPreviousEnd)
    }

    func test_已结束周期_完整对完整() {
        let now = makeDate(2026, 10, 6, 15, 30)
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: .week(anchorDay: makeDate(2026, 9, 24)), asOf: now, calendar: calendar)
        let window = TaskAnalyticsPeriodResolver.compareWindow(current: bounds, asOf: now, calendar: calendar)
        XCTAssertEqual(window.currentStart, makeDate(2026, 9, 21))
        XCTAssertEqual(window.currentEnd, makeDate(2026, 9, 28))
        XCTAssertEqual(window.previousStart, makeDate(2026, 9, 14))
        XCTAssertEqual(window.previousEnd, makeDate(2026, 9, 21))
    }

    func test_上期较短_截到上期结束并标记() {
        // R48：3月31日进行中 vs 2月28天——平移窗口超上期结束时截断
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.firstWeekday = 2
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = nyCalendar.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 12))!
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: .month(anchorDay: now), asOf: now, calendar: nyCalendar)
        XCTAssertTrue(bounds.isOngoing)
        let window = TaskAnalyticsPeriodResolver.compareWindow(current: bounds, asOf: now, calendar: nyCalendar)
        XCTAssertTrue(window.truncatedToPreviousEnd, "3月进行中对比2月应截断到2月结束")
        XCTAssertEqual(window.previousEnd, nyCalendar.date(from: DateComponents(year: 2027, month: 3, day: 1))!)
    }

    func test_自定义等自然日长度上一窗口() {
        let now = makeDate(2026, 10, 6, 15, 30)
        let custom = TaskAnalyticsPeriod.custom(startDay: makeDate(2026, 10, 1), endDay: makeDate(2026, 10, 4))
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: custom, asOf: now, calendar: calendar)
        let window = TaskAnalyticsPeriodResolver.compareWindow(current: bounds, asOf: now, calendar: calendar)
        // 已结束自定义：当前完整 vs 紧邻之前等长窗口（4 天）09-27..09-30
        XCTAssertEqual(window.previousStart, makeDate(2026, 9, 27))
        XCTAssertEqual(window.previousEnd, makeDate(2026, 10, 1))
    }

    // MARK: - 趋势桶粒度

    func test_桶粒度_自定义31天按日_32天按月() {
        // R41
        let asOf = makeDate(2026, 10, 6, 15, 30)
        let d31 = TaskAnalyticsPeriodResolver.bounds(
            of: .custom(startDay: makeDate(2026, 9, 6), endDay: makeDate(2026, 10, 6)), asOf: asOf, calendar: calendar
        )
        XCTAssertEqual(TaskAnalyticsPeriodResolver.bucketGranularity(of: d31, calendar: calendar), .day)
        XCTAssertEqual(TaskAnalyticsPeriodResolver.buckets(of: d31, asOf: asOf, calendar: calendar).count, 31)

        let d32 = TaskAnalyticsPeriodResolver.bounds(
            of: .custom(startDay: makeDate(2026, 9, 5), endDay: makeDate(2026, 10, 6)), asOf: asOf, calendar: calendar
        )
        XCTAssertEqual(TaskAnalyticsPeriodResolver.bucketGranularity(of: d32, calendar: calendar), .month)
        XCTAssertEqual(TaskAnalyticsPeriodResolver.buckets(of: d32, asOf: asOf, calendar: calendar).count, 2)
    }

    func test_跨月自定义_超31天按月桶_与范围相交不带入范围外() {
        let asOf = makeDate(2026, 10, 6, 15, 30)
        // 8-20..10-03 共 45 天（>31）→ 按月；月桶与范围相交裁剪
        let bounds = TaskAnalyticsPeriodResolver.bounds(
            of: .custom(startDay: makeDate(2026, 8, 20), endDay: makeDate(2026, 10, 3)), asOf: asOf, calendar: calendar
        )
        let buckets = TaskAnalyticsPeriodResolver.buckets(of: bounds, asOf: asOf, calendar: calendar)
        XCTAssertEqual(buckets.count, 3, "跨 8/9/10 三个自然月 → 三个月桶")
        XCTAssertEqual(buckets[0].start, makeDate(2026, 8, 20))
        XCTAssertEqual(buckets[0].endExclusive, makeDate(2026, 9, 1))
        XCTAssertEqual(buckets[1].start, makeDate(2026, 9, 1))
        XCTAssertEqual(buckets[1].endExclusive, makeDate(2026, 10, 1))
        XCTAssertEqual(buckets[2].start, makeDate(2026, 10, 1))
        XCTAssertEqual(buckets[2].endExclusive, makeDate(2026, 10, 4))
        XCTAssertFalse(buckets.contains { $0.start < bounds.start })
    }

    func test_桶合计覆盖整周期_无空洞无越界() {
        let asOf = makeDate(2026, 10, 6, 15, 30)
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: .week(anchorDay: asOf), asOf: asOf, calendar: calendar)
        let buckets = TaskAnalyticsPeriodResolver.buckets(of: bounds, asOf: asOf, calendar: calendar)
        XCTAssertEqual(buckets.first?.start, bounds.start)
        XCTAssertEqual(buckets.last?.endExclusive, bounds.endExclusive)
        for pair in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(pair.0.endExclusive, pair.1.start, "桶必须连续无缝")
        }
    }

    // MARK: - DST 日历推进

    func test_DST切换日_日历加天保持同时刻() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let before = ny.date(from: DateComponents(year: 2027, month: 3, day: 13, hour: 9, minute: 30))!
        let after = ny.date(byAdding: .day, value: 1, to: before)!
        XCTAssertEqual(ny.component(.hour, from: after), 9, "DST 切换日用日历加一天应保持 9:30 本地时刻")
        XCTAssertEqual(ny.dateComponents([.day], from: ny.startOfDay(for: before), to: ny.startOfDay(for: after)).day, 1)
    }
}
