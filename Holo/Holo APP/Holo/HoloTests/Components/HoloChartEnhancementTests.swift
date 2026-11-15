//
//  HoloChartEnhancementTests.swift
//  HoloTests
//
//  2026-11-15 图表增强批的纯函数锁定：极值标注、合计环比、堆叠累计、瀑布水位。
//

import XCTest
@testable import Holo

final class HoloChartEnhancementTests: XCTestCase {

    // MARK: - 极值标注

    func testExtremaPicksMaxAndMinAmongValidValues() {
        let values: [Double?] = [3, nil, 9, 5, 1, 7, nil, 4, 6, 2, 8, 5]
        let result = HoloChartGeometry.extremaIndices(values: values)
        XCTAssertEqual(result?.max, 2)
        XCTAssertEqual(result?.min, 4)
    }

    func testExtremaSkippedWhenTooFewPoints() {
        XCTAssertNil(HoloChartGeometry.extremaIndices(values: [1, 5, 3]))
        XCTAssertNil(HoloChartGeometry.extremaIndices(values: [nil, nil, nil, nil, nil, nil]))
    }

    func testExtremaSkippedWhenPeakEqualsValley() {
        // 单点平线（有效点多但值全同 → 峰谷同一下标/同值），没有可讲的故事
        XCTAssertNil(HoloChartGeometry.extremaIndices(values: [4, 4, 4, 4, 4, 4]))
    }

    // MARK: - 合计环比

    func testDeltaPercentNormal() {
        XCTAssertEqual(HoloChartGeometry.deltaPercent(current: 110, previous: 100) ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(HoloChartGeometry.deltaPercent(current: 90, previous: 100) ?? 0, -10, accuracy: 0.001)
    }

    func testDeltaPercentNeedsPositiveBaseline() {
        XCTAssertNil(HoloChartGeometry.deltaPercent(current: 10, previous: 0))
        XCTAssertNil(HoloChartGeometry.deltaPercent(current: 10, previous: -5))
        XCTAssertNil(HoloChartGeometry.deltaPercent(current: .nan, previous: 100))
    }

    // MARK: - 堆叠累计

    func testCumulativeLevelsStackPerBucket() {
        let series = [
            HoloStackedAreaSeries(id: "a", title: "A", color: .holoChart1, values: [2, nil, 3]),
            HoloStackedAreaSeries(id: "b", title: "B", color: .holoChart2, values: [1, 4, 0]),
            HoloStackedAreaSeries(id: "c", title: "C", color: .holoChart5, values: [5, 1, nil])
        ]
        let levels = HoloStackedAreaChart.cumulativeLevels(series: series, bucketCount: 3)
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels[0], [2, 0, 3])          // nil 按 0 层
        XCTAssertEqual(levels[1], [3, 4, 3])
        XCTAssertEqual(levels[2], [8, 5, 3])          // 末桶合计 3
    }

    func testCumulativeLevelsEmptySafe() {
        XCTAssertEqual(HoloStackedAreaChart.cumulativeLevels(series: [], bucketCount: 0).count, 0)
        let levels = HoloStackedAreaChart.cumulativeLevels(series: [], bucketCount: 3)
        XCTAssertEqual(levels.count, 0)
    }

    // MARK: - 瀑布水位

    func testWaterfallLevelsRunAndAnchor() {
        let items = [
            HoloWaterfallItem(id: "open", label: "期初", total: 320),
            HoloWaterfallItem(id: "in", label: "流入", delta: 900),
            HoloWaterfallItem(id: "need", label: "必要", delta: -420),
            HoloWaterfallItem(id: "flex", label: "弹性", delta: -260),
            HoloWaterfallItem(id: "close", label: "期末", total: 540)
        ]
        let levels = HoloWaterfallChart.levels(for: items)
        XCTAssertEqual(levels.map(\.from), [0, 320, 1220, 800, 0])
        XCTAssertEqual(levels.map(\.to), [320, 1220, 800, 540, 540])
        // 期末锚点必须与逐项推演对账：320 + 900 − 420 − 260 = 540
        XCTAssertEqual(levels[3].to, levels[4].to)
    }

    func testWaterfallAnchorResetsRunningLevel() {
        let items = [
            HoloWaterfallItem(id: "a", label: "期初", total: 100),
            HoloWaterfallItem(id: "b", label: "流入", delta: 50),
            HoloWaterfallItem(id: "c", label: "期末", total: 200),
            HoloWaterfallItem(id: "d", label: "流出", delta: -80)
        ]
        let levels = HoloWaterfallChart.levels(for: items)
        XCTAssertEqual(levels[1].to, 150)
        XCTAssertEqual(levels[2].to, 200)   // 锚点重置水位
        XCTAssertEqual(levels[3].from, 200)
        XCTAssertEqual(levels[3].to, 120)
    }

    func testWaterfallFlowRowsExcludeAnchorsAndStartAtZero() {
        let items = [
            HoloWaterfallItem(id: "open", label: "期初", total: 74_660.68),
            HoloWaterfallItem(id: "inc", label: "投资理财", delta: 6_150),
            HoloWaterfallItem(id: "exp", label: "居住", delta: -5_426.22),
            HoloWaterfallItem(id: "close", label: "期末", total: 75_384.46)
        ]
        let rows = HoloWaterfallChart.flowRows(for: items)
        XCTAssertEqual(rows.map(\.item.label), ["投资理财", "居住"])
        XCTAssertEqual(rows[0].from, 0, accuracy: 0.001)
        XCTAssertEqual(rows[0].to, 6_150, accuracy: 0.001)
        XCTAssertEqual(rows[1].from, 6_150, accuracy: 0.001)
        XCTAssertEqual(rows[1].to, 723.78, accuracy: 0.001)
    }

    // MARK: - 现金流瀑布构建（财务）

    func testCashflowMergesAndOrders() {
        let items = FinanceAnalysisState.cashflowItems(
            opening: 320, closing: 540,
            income: [("工资", 900), ("红包", 50)],
            expense: [("房租", 420), ("餐饮", 260), ("交通", 40), ("日用", 30), ("其他", 20)])
        // 期初 / 工资（最大收入类）/ 其他收入 / 支出前三大 / 其余 N 类（不与真实分类「其他」撞名）/ 期末
        XCTAssertEqual(items.map(\.label), ["期初", "工资", "其他收入", "房租", "餐饮", "交通", "其余 2 类", "期末"])
        XCTAssertEqual(items.first?.total, 320)
        XCTAssertEqual(items.last?.total, 540)
        XCTAssertEqual(items[1].delta, 900)
        XCTAssertEqual(items[2].delta, 50)
        XCTAssertEqual(items[3].delta, -420)
        XCTAssertEqual(items[6].delta, -50)   // 日用 30 + 其他 20
    }

    func testCashflowSkipsEmptyIncome() {
        let items = FinanceAnalysisState.cashflowItems(
            opening: 100, closing: 80, income: [], expense: [("餐饮", 20)])
        XCTAssertEqual(items.map(\.label), ["期初", "餐饮", "期末"])
        XCTAssertEqual(items[2].total, 80)
    }

    func testCashflowFromPointsDerivesOpening() {
        let base = Date(timeIntervalSince1970: 0)
        let points = [
            ChartDataPoint(date: base, label: "1月", expense: 100, income: 500, transactionCount: 3, balance: 720),
            ChartDataPoint(date: base.addingTimeInterval(86_400), label: "2月", expense: 80, income: 400, transactionCount: 2, balance: 1040)
        ]
        let items = FinanceAnalysisState.cashflowItems(points: points, expenseAggregations: [], incomeAggregations: [])
        XCTAssertEqual(items.first?.total, 320)   // 720 − 500 + 100
        XCTAssertEqual(items.last?.total, 1040)
    }
}
