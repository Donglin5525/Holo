//
//  FinancePeriodDirectSelectTests.swift
//  HoloTests
//
//  统计页时间筛选回归：季度胶囊文案（防「年年」复发）、翻页闸门、季度窗口跨年平移。
//  只测纯函数，不经 FinancePeriodSettings 单例。
//

import XCTest
@testable import Holo

final class FinancePeriodDirectSelectTests: XCTestCase {

    private let calendar = FinancePeriodDirectSelectTests.fixedCalendar()

    // MARK: - 胶囊文案（防「年年」复发）

    func test_pillLabel_yearNeverDoublesYearCharacter() {
        let label = TimeRange.pillLabel(
            timeRange: .year,
            start: date(2026, 1, 1),
            end: date(2027, 1, 1)
        )
        XCTAssertFalse(label.contains("年年"), "年档胶囊不得出现「年年」，实际「\(label)」")
        XCTAssertTrue(label.contains("2026"), "年档胶囊应包含年份 2026，实际「\(label)」")
    }

    func test_pillLabel_quarterShowsQuarterIndex() {
        let label = TimeRange.pillLabel(
            timeRange: .quarter,
            start: date(2025, 1, 1),
            end: date(2025, 4, 1)
        )
        XCTAssertEqual(label, "2025年第1季度", "季度胶囊应标「年份年第N季度」，实际「\(label)」")
    }

    func test_pillLabel_defaultShowsDateRange() {
        let label = TimeRange.pillLabel(
            timeRange: .month,
            start: date(2026, 9, 1),
            end: date(2026, 10, 1)
        )
        XCTAssertFalse(label.isEmpty, "月档胶囊保持日期区间")
        XCTAssertFalse(label.contains("第"), "月档不出现季度文案")
    }

    // MARK: - 翻页闸门（右箭头未来钳制）

    func test_nextGate_blocksCurrentAndFutureWindows() {
        let now = date(2026, 9, 27)
        XCTAssertFalse(
            FinanceAnalysisNextGate.canNavigateNext(rangeEnd: date(2026, 10, 1), now: now),
            "当前月窗口（end 10/1 未到）禁用右翻"
        )
        XCTAssertFalse(
            FinanceAnalysisNextGate.canNavigateNext(rangeEnd: date(2027, 1, 1), now: now),
            "未来窗口禁用右翻"
        )
        XCTAssertTrue(
            FinanceAnalysisNextGate.canNavigateNext(rangeEnd: date(2025, 4, 1), now: now),
            "历史窗口允许右翻返回"
        )
        XCTAssertTrue(
            FinanceAnalysisNextGate.canNavigateNext(rangeEnd: now, now: now),
            "end 恰为 now（已走完的窗口）允许右翻"
        )
    }

    // MARK: - 季度窗口跨年平移

    func test_navigator_quarterShiftAcrossYearBoundary() {
        // 2025Q4 → 下一季 = 2026Q1
        let next = FinanceDateRangeNavigator.shiftedRange(
            start: date(2025, 10, 1),
            end: date(2026, 1, 1),
            timeRange: .quarter,
            direction: .next,
            calendar: calendar
        )
        XCTAssertEqual(next?.start, date(2026, 1, 1), "2025Q4 右翻进入 2026Q1")
        XCTAssertEqual(next?.end, date(2026, 4, 1))

        // 2026Q1 → 上一季 = 2025Q4
        let previous = FinanceDateRangeNavigator.shiftedRange(
            start: date(2026, 1, 1),
            end: date(2026, 4, 1),
            timeRange: .quarter,
            direction: .previous,
            calendar: calendar
        )
        XCTAssertEqual(previous?.start, date(2025, 10, 1), "2026Q1 左翻回到 2025Q4")
        XCTAssertEqual(previous?.end, date(2026, 1, 1))
    }

    func test_navigator_recognizesNaturalQuarterCustomWindow() {
        // 自定义窗口恰好是自然季时按季平移（识别顺序：年→季→月）
        let shifted = FinanceDateRangeNavigator.shiftedRange(
            start: date(2025, 4, 1),
            end: date(2025, 7, 1),
            timeRange: .custom,
            direction: .next,
            calendar: calendar
        )
        XCTAssertEqual(shifted?.start, date(2025, 7, 1), "自定义 Q2 窗口右翻按季平移")
        XCTAssertEqual(shifted?.end, date(2025, 10, 1))
    }

    // MARK: - 辅助

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.fixedCalendar().date(from: DateComponents(year: year, month: month, day: day))!
    }
}
