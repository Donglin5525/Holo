//
//  HabitReviewTrendChartLayoutTests.swift
//  HoloTests
//
//  2026-10-07 回顾趋势图几何回归（东林实报柱子/刻度/数值对不上、柱体过粗）：
//  柱宽 pt 封顶、图域覆盖完整范围、槽位与触摸命中映射、刻度节奏。
//  与财务 ChartBarPairLayout 同一套画法契约。
//

import XCTest
@testable import Holo

final class HabitReviewTrendChartLayoutTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: 柱宽

    func test_柱宽_短范围基准6pt不随槽位变胖() {
        XCTAssertEqual(ReviewTrendChartLayout.barWidthPt(dayCount: 7, slotWidthPt: 45), 6,
                       "7 天宽槽柱宽必须是固定 6pt，不能按槽宽撑满")
    }

    func test_柱宽_长范围收细到3_2pt() {
        XCTAssertEqual(ReviewTrendChartLayout.barWidthPt(dayCount: 30, slotWidthPt: 8), 3.2, accuracy: 0.001)
    }

    func test_柱宽_槽位极窄按槽宽收缩_下限1pt() {
        XCTAssertEqual(ReviewTrendChartLayout.barWidthPt(dayCount: 400, slotWidthPt: 1), 1, accuracy: 0.001)
        XCTAssertEqual(ReviewTrendChartLayout.barWidthPt(dayCount: 400, slotWidthPt: 3), 2.1, accuracy: 0.001)
    }

    // MARK: 域

    func test_域两侧各留半槽() {
        XCTAssertEqual(ReviewTrendChartLayout.xDomain(dayCount: 7), -0.5...6.5)
        XCTAssertEqual(ReviewTrendChartLayout.xDomain(dayCount: 0), -0.5...0.5)
    }

    // MARK: 槽位映射

    func test_槽位下标按自然日偏移() {
        let start = day(2026, 10, 1)
        XCTAssertEqual(ReviewTrendChartLayout.slotIndex(of: day(2026, 10, 1), rangeStart: start, dayCount: 7, calendar: calendar), 0)
        XCTAssertEqual(ReviewTrendChartLayout.slotIndex(of: day(2026, 10, 4), rangeStart: start, dayCount: 7, calendar: calendar), 3)
        XCTAssertEqual(ReviewTrendChartLayout.slotIndex(of: day(2026, 10, 7), rangeStart: start, dayCount: 7, calendar: calendar), 6)
    }

    func test_槽位下标_域外返回nil() {
        let start = day(2026, 10, 1)
        XCTAssertNil(ReviewTrendChartLayout.slotIndex(of: day(2026, 9, 30), rangeStart: start, dayCount: 7, calendar: calendar))
        XCTAssertNil(ReviewTrendChartLayout.slotIndex(of: day(2026, 10, 8), rangeStart: start, dayCount: 7, calendar: calendar))
    }

    // MARK: 触摸命中

    func test_触摸命中_按槽位比例钳到两端() {
        XCTAssertEqual(ReviewTrendChartLayout.touchedSlot(touchXInPlot: 0, plotWidth: 300, dayCount: 7), 0)
        XCTAssertEqual(ReviewTrendChartLayout.touchedSlot(touchXInPlot: 150, plotWidth: 300, dayCount: 7), 3)
        XCTAssertEqual(ReviewTrendChartLayout.touchedSlot(touchXInPlot: 299, plotWidth: 300, dayCount: 7), 6)
        XCTAssertEqual(ReviewTrendChartLayout.touchedSlot(touchXInPlot: -50, plotWidth: 300, dayCount: 7), 0)
        XCTAssertEqual(ReviewTrendChartLayout.touchedSlot(touchXInPlot: 500, plotWidth: 300, dayCount: 7), 6)
        XCTAssertNil(ReviewTrendChartLayout.touchedSlot(touchXInPlot: 10, plotWidth: 0, dayCount: 7))
    }

    // MARK: 刻度节奏

    func test_刻度_短范围逐日() {
        XCTAssertEqual(ReviewTrendChartLayout.tickSlots(dayCount: 7), Array(0..<7))
        XCTAssertEqual(ReviewTrendChartLayout.tickSlots(dayCount: 10), Array(0..<10))
        XCTAssertEqual(ReviewTrendChartLayout.tickSlots(dayCount: 1), [0])
        XCTAssertTrue(ReviewTrendChartLayout.tickSlots(dayCount: 0).isEmpty)
    }

    func test_刻度_长范围5格均匀加末日_无重复() {
        let ticks = ReviewTrendChartLayout.tickSlots(dayCount: 30)
        XCTAssertEqual(ticks.count, Set(ticks).count, "刻度槽位不得重复")
        XCTAssertEqual(ticks.first, 0)
        XCTAssertEqual(ticks.last, 29)
        XCTAssertLessThanOrEqual(ticks.count, 6)
    }

    // MARK: 图域

    func test_图域_近7天保持完整范围() {
        let interval = DateInterval(start: day(2026, 10, 1), end: day(2026, 10, 8))
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 7), values: [], calendar: calendar)
        XCTAssertEqual(range.start, day(2026, 10, 1))
        XCTAssertEqual(range.dayCount, 7)
    }

    func test_图域_本月内未来日不占槽() {
        // 十月整月（10/1~11/1 半开）今天 10/7：域只到 10/7，未来日留白不画空槽
        let interval = DateInterval(start: day(2026, 10, 1), end: day(2026, 11, 1))
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 7), values: [], calendar: calendar)
        XCTAssertEqual(range.start, day(2026, 10, 1))
        XCTAssertEqual(range.dayCount, 7)
    }

    func test_图域_全部记录跨年收敛到首末记录日() {
        let interval = DateInterval(start: day(2024, 1, 1), end: day(2026, 10, 8))
        let values = [
            HabitDailyNumericValue(date: day(2026, 9, 10), value: 2),
            HabitDailyNumericValue(date: day(2026, 10, 7), value: 5),
        ]
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 7), values: values, calendar: calendar)
        XCTAssertEqual(range.start, day(2026, 9, 10))
        XCTAssertEqual(range.dayCount, 28)
    }
}
