//
//  CalendarRangeBuilderTests.swift
//  HoloTests
//
//  区间生成单测（统一半开 [start,end)、周一首、跨月/月末边界）
//

import XCTest
@testable import Holo

final class CalendarRangeBuilderTests: XCTestCase {

    /// 用 Calendar.current 造确定性日期（与 RangeBuilder 同一时区，避免 CI 时区 flaky）
    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    // MARK: - weekRange（周一首）

    func test_weekRange周中输入返回周一首区间() {
        // 2026-07-01 是周三，所在周从 2026-06-29（周一）起
        let wed = makeDate(year: 2026, month: 7, day: 1)
        let range = CalendarRangeBuilder.weekRange(around: wed)

        let mon = makeDate(year: 2026, month: 6, day: 29)
        XCTAssertEqual(range.start, mon, "周中应归属本周，起点为周一")
        XCTAssertEqual(range.duration, 7 * 24 * 3600, accuracy: 1, "周跨度 7 天")
    }

    func test_weekRange周日输入仍归属本周() {
        // 2026-07-05 是周日（该周最后一天），仍归属 2026-06-29 起的那周
        let sun = makeDate(year: 2026, month: 7, day: 5)
        let range = CalendarRangeBuilder.weekRange(around: sun)

        let mon = makeDate(year: 2026, month: 6, day: 29)
        XCTAssertEqual(range.start, mon, "周日应归属本周，而非下周")
    }

    func test_weekRange跨月边界() {
        // 2026-07-31 是周五，所在周从 2026-07-27（周一）起
        let fri = makeDate(year: 2026, month: 7, day: 31)
        let range = CalendarRangeBuilder.weekRange(around: fri)

        let mon = makeDate(year: 2026, month: 7, day: 27)
        XCTAssertEqual(range.start, mon, "跨月周仍以本周一为起点")
    }

    // MARK: - dayRange

    func test_dayRange返回当日零点到次日零点() {
        let noon = makeDate(year: 2026, month: 7, day: 1, hour: 12)
        let range = CalendarRangeBuilder.dayRange(noon)

        let dayStart = makeDate(year: 2026, month: 7, day: 1)
        XCTAssertEqual(range.start, dayStart)
        XCTAssertEqual(range.duration, 24 * 3600, accuracy: 1)
    }

    func test_dayRange月末23点仍在当日() {
        let endOfMonth = makeDate(year: 2026, month: 7, day: 31, hour: 23)
        let range = CalendarRangeBuilder.dayRange(endOfMonth)

        let dayStart = makeDate(year: 2026, month: 7, day: 31)
        XCTAssertEqual(range.start, dayStart, "月末 23:59 仍属当日")
    }

    // MARK: - 半开区间语义

    func test_半开区间_start在内end不在内() {
        let wed = makeDate(year: 2026, month: 7, day: 1, hour: 9)
        let range = CalendarRangeBuilder.weekRange(around: wed)

        XCTAssertTrue(range.contains(range.start), "start 应在区间内")
        XCTAssertFalse(range.contains(range.end), "end 应不在区间内（半开）")
    }

    func test_半开区间_次日零点不在当日() {
        // 月末次日 00:00 不应进入当日（边界去重关键）
        let day = makeDate(year: 2026, month: 7, day: 31, hour: 12)
        let nextDayZero = makeDate(year: 2026, month: 8, day: 1, hour: 0)
        let range = CalendarRangeBuilder.dayRange(day)

        XCTAssertTrue(range.contains(day))
        XCTAssertFalse(range.contains(nextDayZero), "次日 00:00 不应计入当日（半开上界）")
    }
}
