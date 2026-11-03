//
//  CalendarHelpersTests.swift
//  HoloTests
//
//  日期工具纯函数验证。重点锁 shiftingToMonth（账本翻月选中日迁移口径，
//  2026-10-09 东林拍板：保号数迁月，无该号钳到月末）。
//

import XCTest
@testable import Holo

final class CalendarHelpersTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func assertDay(_ date: Date, _ y: Int, _ m: Int, _ d: Int,
                           _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, y, message, file: file, line: line)
        XCTAssertEqual(comps.month, m, message, file: file, line: line)
        XCTAssertEqual(comps.day, d, message, file: file, line: line)
    }

    func test_同号迁移_普通日期() {
        assertDay(day(2026, 1, 15).shiftingToMonth(day(2026, 2, 1)), 2026, 2, 15, "同号直接迁")
        assertDay(day(2026, 10, 15).shiftingToMonth(day(2026, 9, 1)), 2026, 9, 15, "往回翻同样保号")
    }

    func test_目标月无该号钳到月末() {
        assertDay(day(2026, 1, 31).shiftingToMonth(day(2026, 2, 1)), 2026, 2, 28, "平年 2 月钳 28")
        assertDay(day(2026, 3, 31).shiftingToMonth(day(2026, 4, 1)), 2026, 4, 30, "4 月 30 天钳 30")
        assertDay(day(2026, 8, 31).shiftingToMonth(day(2026, 9, 1)), 2026, 9, 30, "9 月 30 天钳 30")
    }

    func test_闰年二月钳29_非闰年钳28() {
        assertDay(day(2024, 1, 31).shiftingToMonth(day(2024, 2, 1)), 2024, 2, 29, "闰年 2 月钳 29")
        assertDay(day(2024, 3, 31).shiftingToMonth(day(2025, 2, 1)), 2025, 2, 28, "次年非闰年钳 28")
    }

    func test_跨年迁移_保号与钳末都成立() {
        assertDay(day(2026, 10, 15).shiftingToMonth(day(2027, 3, 1)), 2027, 3, 15, "跨年保号")
        assertDay(day(2026, 12, 31).shiftingToMonth(day(2027, 2, 1)), 2027, 2, 28, "跨年+钳末")
    }

    func test_同月迁移_原样返回() {
        let same = day(2026, 10, 15).shiftingToMonth(day(2026, 10, 20))
        assertDay(same, 2026, 10, 15, "同月迁移不改动号数")
    }

    func test_迁移结果落在目标月的零点_不携带源时刻() {
        // 源日期带时刻（如 9/15 14:30），迁移后应为目标月对应日的 00:00，
        // 与月历选中格/当日查询的 startOfDay 口径一致
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 15; comps.hour = 14; comps.minute = 30
        let withTime = calendar.date(from: comps)!
        let shifted = withTime.shiftingToMonth(day(2026, 8, 1))
        assertDay(shifted, 2026, 8, 15, "保号迁月")
        XCTAssertEqual(calendar.component(.hour, from: shifted), 0, "落零点")
    }
}
