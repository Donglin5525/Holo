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

    // MARK: 刻度标签预算（2026-10-26：「3/184/24」两端标签贴死根治）

    /// 预算与实际标签框必须是同一个数：相邻刻度的中心距 ≥ 框宽，
    /// 否则两端标签被钳进图内时必与邻居互压（44pt 旧预算的病根）
    func test_刻度预算_相邻刻度中心距不小于标签框宽() {
        for width: CGFloat in [120, 200, 264, 323, 390, 500] {
            let labelWidth = HoloChartGeometry.tickLabelWidth(plotWidth: width)
            let ticks = HoloChartGeometry.tickIndices(count: 223, width: width)
            XCTAssertGreaterThanOrEqual(ticks.count, 3, "width=\(width) 刻度过少")
            for pair in zip(ticks, ticks.dropFirst()) {
                let spacing = width * CGFloat(pair.1 - pair.0) / CGFloat(223 - 1)
                XCTAssertGreaterThanOrEqual(spacing, labelWidth,
                    "width=\(width) 刻度间距 \(spacing) < 框宽 \(labelWidth)，必然重叠")
            }
        }
    }

    func test_刻度预算_常用屏宽下数量收敛() {
        // 390pt 屏旧预算 8-9 个（互相压死），新预算 ≤ 7
        XCTAssertLessThanOrEqual(HoloChartGeometry.tickIndices(count: 223, width: 323).count, 7)
        XCTAssertEqual(HoloChartGeometry.tickIndices(count: 223, width: 323).first, 0)
        XCTAssertEqual(HoloChartGeometry.tickIndices(count: 223, width: 323).last, 222)
        XCTAssertEqual(HoloChartGeometry.tickIndices(count: 5, width: 323), [0, 1, 2, 3, 4], "桶少于容量时逐桶标注")
        XCTAssertEqual(HoloChartGeometry.tickIndices(count: 1, width: 323), [0])
    }

    // MARK: 连续坐标刻度（测量记录点 position 域）

    func test_连续刻度_贪心间距不小于标签框宽_末桶必留() {
        let width: CGFloat = 323
        let labelWidth = HoloChartGeometry.tickLabelWidth(plotWidth: width)
        // 223 天跨度 5 个记录点，位置随真实时间分布
        let positions: [CGFloat] = [0, 12, 150.5, 240, 322]
        let ticks = HoloChartGeometry.tickIndicesForPositions(pixelPositions: positions, minSpacing: labelWidth)
        XCTAssertGreaterThan(ticks.count, 1)
        for pair in zip(ticks, ticks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(positions[pair.1] - positions[pair.0], labelWidth)
        }
        XCTAssertEqual(ticks.last, positions.count - 1, "末桶（最近记录）必须可见")
    }

    func test_连续刻度_密集簇只留末日不重叠() {
        let labelWidth = HoloChartGeometry.tickLabelWidth(plotWidth: 323)
        let positions: [CGFloat] = [10, 14, 18, 22]
        let ticks = HoloChartGeometry.tickIndicesForPositions(pixelPositions: positions, minSpacing: labelWidth)
        XCTAssertEqual(ticks, [positions.count - 1], "整簇挤在一个框宽内只留最后一个")
    }

    // MARK: 测量型记录点布局（position 域）

    func test_测量记录点_按距首记录日天数定位() {
        let values = [
            HabitDailyNumericValue(date: day(2026, 3, 18), value: 84),
            HabitDailyNumericValue(date: day(2026, 3, 19), value: 83.5),
            HabitDailyNumericValue(date: day(2026, 9, 19), value: 82),
            HabitDailyNumericValue(date: day(2026, 10, 26), value: 82.2),
        ]
        let layout = ReviewTrendChartLayout.measurePositions(values: values, calendar: calendar)
        XCTAssertEqual(layout.start, day(2026, 3, 18))
        XCTAssertEqual(layout.positions, [0, 1, 185, 222])
    }

    func test_测量记录点_空值与单点() {
        let empty = ReviewTrendChartLayout.measurePositions(values: [], calendar: calendar)
        XCTAssertTrue(empty.positions.isEmpty)
        let single = ReviewTrendChartLayout.measurePositions(
            values: [HabitDailyNumericValue(date: day(2026, 10, 26), value: 82.2)], calendar: calendar)
        XCTAssertEqual(single.positions, [0], "单条记录 position=0，靠域边距留呼吸位")
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

    // MARK: 稀疏收敛（概览弹层；2026-10-11 东林实报 30 槽孤柱）

    func test_图域_稀疏收敛_仅今天一条记录_收敛三天域不越今天() {
        let interval = DateInterval(start: day(2026, 9, 12), end: day(2026, 10, 12))
        let values = [HabitDailyNumericValue(date: day(2026, 10, 11), value: 3)]
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 11), values: values,
            calendar: calendar, sparseCollapse: true)
        XCTAssertEqual(range.start, day(2026, 10, 9))
        XCTAssertEqual(range.dayCount, 3, "单日记录应收敛到 3 槽，末日不越过今天")
    }

    func test_图域_稀疏收敛_跨度六天内_首末各留一天呼吸位() {
        let interval = DateInterval(start: day(2026, 9, 12), end: day(2026, 10, 12))
        let values = [
            HabitDailyNumericValue(date: day(2026, 10, 2), value: 1),
            HabitDailyNumericValue(date: day(2026, 10, 6), value: 2),
        ]
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 11), values: values,
            calendar: calendar, sparseCollapse: true)
        XCTAssertEqual(range.start, day(2026, 10, 1))
        XCTAssertEqual(range.dayCount, 7)
    }

    func test_图域_稀疏收敛关闭_维持完整范围() {
        let interval = DateInterval(start: day(2026, 9, 12), end: day(2026, 10, 12))
        let values = [HabitDailyNumericValue(date: day(2026, 10, 11), value: 3)]
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 11), values: values,
            calendar: calendar, sparseCollapse: false)
        XCTAssertEqual(range.start, day(2026, 9, 12))
        XCTAssertEqual(range.dayCount, 30, "回顾页语义（空槽如实留白）不受稀疏收敛影响")
    }

    func test_图域_稀疏收敛_跨度七天不触发() {
        let interval = DateInterval(start: day(2026, 9, 12), end: day(2026, 10, 12))
        let values = [
            HabitDailyNumericValue(date: day(2026, 10, 1), value: 1),
            HabitDailyNumericValue(date: day(2026, 10, 8), value: 2),
        ]
        let range = ReviewTrendChartLayout.chartRange(
            interval: interval, today: day(2026, 10, 11), values: values,
            calendar: calendar, sparseCollapse: true)
        XCTAssertEqual(range.start, day(2026, 9, 12))
        XCTAssertEqual(range.dayCount, 30)
    }
}
