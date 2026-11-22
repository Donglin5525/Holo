//
//  MemoryAlmanacTests.swift
//  HoloTests
//
//  记忆长廊年鉴卡：年鉴生成器（纯函数）测试——月份天数、日期分类、档位、开始记录日、往年。
//

import XCTest
@testable import Holo

final class MemoryAlmanacTests: XCTestCase {

    // MARK: - 固定日历（上海时区公历），保证结果与运行机器无关

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        let components = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: components) else {
            XCTFail("无效日期 \(y)-\(m)-\(d)")
            return Date.distantPast
        }
        return date
    }

    private func build(
        year: Int = 2026,
        counts: [Date: Int] = [:],
        today: Date? = nil,
        firstRecord: Date? = nil
    ) -> MemoryAlmanacYear {
        MemoryAlmanacBuilder.build(
            year: year,
            dayCounts: counts,
            today: today ?? day(2026, 11, 21),
            firstRecordDate: firstRecord,
            calendar: calendar
        )
    }

    private func dayCell(_ almanac: MemoryAlmanacYear, _ m: Int, _ d: Int) -> MemoryAlmanacDay? {
        almanac.months.first { $0.month == m }?.days.first { calendar.component(.day, from: $0.date) == d }
    }

    // MARK: - 月份结构

    func testBuildsTwelveMonthsWithCalendarDayCounts() {
        let almanac = build(firstRecord: day(2025, 1, 1))
        XCTAssertEqual(almanac.months.map(\.month), Array(1...12))
        XCTAssertEqual(almanac.months.map(\.dayCount), [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
        XCTAssertEqual(almanac.months.map { $0.days.count }, almanac.months.map(\.dayCount))
    }

    func testLeapYearFebruaryHas29Days() {
        let almanac = build(year: 2028, today: day(2028, 3, 1), firstRecord: day(2027, 1, 1))
        XCTAssertEqual(almanac.months[1].dayCount, 29)
    }

    // MARK: - 日期分类

    func testTodayFutureAndPastKinds() {
        let almanac = build(counts: [day(2026, 11, 21): 4], firstRecord: day(2026, 1, 1))
        XCTAssertEqual(dayCell(almanac, 11, 21)?.kind, .today)
        XCTAssertEqual(dayCell(almanac, 11, 22)?.kind, .future)
        XCTAssertEqual(dayCell(almanac, 11, 20)?.kind, .past)
        XCTAssertEqual(dayCell(almanac, 11, 20)?.level, 0, "过去没记的日子档位为 0")
    }

    func testTodayWithoutRecordIsStillToday() {
        let almanac = build(firstRecord: day(2026, 1, 1))
        XCTAssertEqual(dayCell(almanac, 11, 21)?.kind, .today)
        XCTAssertEqual(dayCell(almanac, 11, 21)?.level, 0)
    }

    // MARK: - 档位：1–2 少 / 3–5 中 / 6+ 多

    func testLevelBoundaries() {
        XCTAssertEqual([0, 1, 2, 3, 5, 6, 12].map(MemoryAlmanacDay.level(for:)), [0, 1, 1, 2, 2, 3, 3])
        XCTAssertEqual(MemoryAlmanacDay.level(for: -1), 0, "异常负数按没记处理")
    }

    // MARK: - 月份状态与合计

    func testMonthStatesAndRecordedDays() {
        let counts = [day(2026, 10, 1): 2, day(2026, 10, 2): 1, day(2026, 11, 3): 7]
        let almanac = build(counts: counts, firstRecord: day(2026, 1, 1))
        XCTAssertEqual(almanac.months[9].state, .past)
        XCTAssertEqual(almanac.months[10].state, .current)
        XCTAssertEqual(almanac.months[11].state, .future)
        XCTAssertEqual(almanac.months[9].recordedDays, 2)
        XCTAssertEqual(almanac.months[10].recordedDays, 1)
        XCTAssertEqual(almanac.months[11].recordedDays, 0)
    }

    func testTotalsIgnoreFutureAndOtherYears() {
        let counts = [
            day(2026, 3, 1): 2,
            day(2026, 11, 21): 3,
            day(2026, 12, 5): 9,   // 未来日期（如提前排的任务），不计入
            day(2025, 12, 31): 4,  // 去年，不计入
            day(2027, 1, 1): 1     // 明年，不计入
        ]
        let almanac = build(counts: counts, firstRecord: day(2025, 12, 31))
        XCTAssertEqual(almanac.recordedDays, 2)
        XCTAssertEqual(almanac.totalCount, 5)
    }

    func testDayOfYearOnlyForCurrentYear() {
        XCTAssertEqual(build(firstRecord: day(2026, 1, 1)).dayOfYear, 325)
        XCTAssertEqual(build(today: day(2026, 1, 1), firstRecord: day(2026, 1, 1)).dayOfYear, 1)
        XCTAssertNil(build(year: 2025, firstRecord: day(2025, 1, 1)).dayOfYear)
    }

    // MARK: - 开始记录日（新用户 / 往年开始 / 从未记录）

    func testNewUserStartingMidYear() {
        let counts = [day(2026, 11, 19): 2, day(2026, 11, 20): 1, day(2026, 11, 21): 3]
        let almanac = build(counts: counts, firstRecord: day(2026, 11, 19))
        XCTAssertEqual(almanac.months[0...9].map(\.state), Array(repeating: .notStarted, count: 10))
        XCTAssertEqual(almanac.months[10].state, .current)
        XCTAssertEqual(dayCell(almanac, 11, 18)?.kind, .notStarted)
        XCTAssertEqual(dayCell(almanac, 11, 19)?.kind, .past)
        XCTAssertEqual(almanac.startDate, day(2026, 11, 19))
        XCTAssertEqual(almanac.recordedDays, 3)
        XCTAssertEqual(almanac.totalCount, 6)
    }

    func testStartInPreviousYearMeansWholeYearStarted() {
        let almanac = build(firstRecord: day(2025, 6, 1))
        XCTAssertNil(almanac.startDate)
        XCTAssertFalse(almanac.months.contains { $0.state == .notStarted })
    }

    func testNoRecordsEverMeansNothingStarted() {
        let almanac = build(firstRecord: nil)
        XCTAssertEqual(almanac.recordedDays, 0)
        XCTAssertTrue(almanac.months.filter { $0.month < 11 }.allSatisfy { $0.state == .notStarted })
        XCTAssertEqual(dayCell(almanac, 11, 21)?.kind, .today, "今天始终标出，作为「从今天开始」的落点")
    }

    // MARK: - 往年

    func testPastYearHasNoTodayOrFuture() {
        let counts = [day(2025, 12, 31): 2]
        let almanac = build(year: 2025, counts: counts, firstRecord: day(2025, 1, 1))
        XCTAssertTrue(almanac.months.allSatisfy { $0.state == .past })
        XCTAssertFalse(almanac.months.flatMap(\.days).contains { $0.kind == .today || $0.kind == .future })
        XCTAssertEqual(almanac.recordedDays, 1)
    }

    func testCountsKeyedByNonMidnightDateAreNormalized() {
        // 上游按 startOfDay 归一，这里再兜一层：同一天不同时刻的键合并计数
        let noon = calendar.date(byAdding: .hour, value: 12, to: day(2026, 5, 1)) ?? day(2026, 5, 1)
        let almanac = build(counts: [day(2026, 5, 1): 1, noon: 2], firstRecord: day(2026, 1, 1))
        XCTAssertEqual(dayCell(almanac, 5, 1)?.count, 3)
    }
}
