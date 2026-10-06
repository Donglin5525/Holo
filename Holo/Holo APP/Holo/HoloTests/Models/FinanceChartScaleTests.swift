//
//  FinanceChartScaleTests.swift
//  HoloTests
//
//  财务图表坐标缩放测试
//

import XCTest
@testable import Holo

final class FinanceChartScaleTests: XCTestCase {

    func testBalanceScaleMapsLargeBalanceIntoAmountAxisRange() {
        let scale = BalanceChartScale(
            amountValues: [120, 240, 360],
            balanceValues: [10_000, 15_000, 20_000]
        )

        XCTAssertEqual(scale.amountAxisMax, 414, accuracy: 0.001)
        XCTAssertEqual(scale.balanceAxisMax, 20_000)
        XCTAssertEqual(scale.scaledBalance(20_000), 414, accuracy: 0.001)
        XCTAssertEqual(scale.scaledBalance(10_000), 207, accuracy: 0.001)
    }

    func testBalanceScaleHandlesNegativeBalanceRange() {
        let scale = BalanceChartScale(
            amountValues: [100, 200],
            balanceValues: [-5_000, 0, 5_000]
        )

        XCTAssertEqual(scale.amountAxisMin, 0)
        XCTAssertEqual(scale.amountAxisMax, 230, accuracy: 0.001)
        XCTAssertEqual(scale.balanceAxisMin, -5_000)
        XCTAssertEqual(scale.balanceAxisMax, 5_000)
        XCTAssertEqual(scale.scaledBalance(-5_000), 0, accuracy: 0.001)
        XCTAssertEqual(scale.scaledBalance(0), 115, accuracy: 0.001)
        XCTAssertEqual(scale.scaledBalance(5_000), 230, accuracy: 0.001)
    }

    func testBalanceScaleKeepsConstantBalanceVisible() {
        let scale = BalanceChartScale(
            amountValues: [1_000, 2_000],
            balanceValues: [50_000, 50_000]
        )

        XCTAssertGreaterThan(scale.balanceAxisMax, scale.balanceAxisMin)
        XCTAssertEqual(
            scale.scaledBalance(50_000),
            scale.amountAxisMax,
            accuracy: 0.001
        )
    }

    func testOverviewChartUsesMatchingAxisTickCounts() {
        let scale = BalanceChartScale(
            amountValues: [8_000, 26_000],
            balanceValues: [20_000, 44_000]
        )

        XCTAssertEqual(FinanceChartAxisTicks.overviewTickCount, 5)
        XCTAssertEqual(
            FinanceChartAxisTicks.amountTicks(min: scale.amountAxisMin, max: scale.amountAxisMax).count,
            FinanceChartAxisTicks.overviewTickCount
        )
        XCTAssertEqual(
            FinanceChartAxisTicks.balanceTicks(for: scale).count,
            FinanceChartAxisTicks.overviewTickCount
        )
    }

    func testTouchSelectionUsesPlotLocalCoordinates() {
        let positions: [CGFloat] = [0, 100, 200, 300, 400]

        XCTAssertEqual(
            ChartTouchSelection.nearestPointIndex(
                touchXInPlot: 398,
                plotWidth: 400,
                pointXPositions: positions
            ),
            4
        )
        XCTAssertEqual(
            ChartTouchSelection.nearestPointIndex(
                touchXInPlot: 302,
                plotWidth: 400,
                pointXPositions: positions
            ),
            3
        )
        XCTAssertNil(
            ChartTouchSelection.nearestPointIndex(
                touchXInPlot: 520,
                plotWidth: 400,
                pointXPositions: positions
            )
        )
    }

    func testPieChartDoesNotDimOtherSectorsWhenOneCategoryIsFocused() {
        XCTAssertEqual(
            PieChartInteractionStyle.sectorOpacity(isFocused: false, hasFocusedCategory: true),
            1.0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            PieChartInteractionStyle.labelOpacity(isFocused: false, hasFocusedCategory: true),
            1.0,
            accuracy: 0.001
        )
    }

    func testCategoryAnalysisPieChartUsesPaletteInsteadOfCategoryColors() {
        XCTAssertTrue(FinanceCategoryChartColor.shouldUseChartPaletteForCategoryAnalysis())
    }

    func testPieChartTracksHorizontalMoveButLeavesVerticalDragForPageScroll() {
        XCTAssertTrue(
            PieChartInteractionStyle.shouldTrackHighlight(translation: CGSize(width: 28, height: 8))
        )
        XCTAssertFalse(
            PieChartInteractionStyle.shouldTrackHighlight(translation: CGSize(width: 8, height: 28))
        )
    }

    func testPieChartInsetDoesNotReverseTinySectors() {
        let tinySectorSpan = 1.08
        let inset = PieChartInteractionStyle.sectorInsetAngle(
            spanAngle: tinySectorSpan,
            preferredInset: 1.5
        )

        XCTAssertGreaterThan(tinySectorSpan - inset, 0)
        XCTAssertLessThan(inset, tinySectorSpan)
    }

    func testCompactAxisAmountShowsMidTickExactly() {
        // 2.5万上限的中档刻度是 1.25万：一位小数会写成 1.2万，
        // 与顶格「2.5万」同图对不上账（2026-10-03 东林项目页签截图实报）
        XCTAssertEqual(NumberFormatter.compactAxisAmount(0), "0")
        XCTAssertEqual(NumberFormatter.compactAxisAmount(0.5), "")
        XCTAssertEqual(NumberFormatter.compactAxisAmount(500), "500")
        XCTAssertTrue(NumberFormatter.compactAxisAmount(12_500).hasPrefix("1.25"), String(NumberFormatter.compactAxisAmount(12_500)))
        XCTAssertTrue(NumberFormatter.compactAxisAmount(25_000).hasPrefix("2.5"), String(NumberFormatter.compactAxisAmount(25_000)))
        XCTAssertTrue(NumberFormatter.compactAxisAmount(1_500).hasPrefix("1.5"), String(NumberFormatter.compactAxisAmount(1_500)))
        XCTAssertEqual(NumberFormatter.compactAxisAmount(800), "800")
    }

    func testPieChartUsesChartPaletteForImportedPlaceholderGrayCategories() {
        XCTAssertTrue(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#64748B"))
        XCTAssertTrue(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#6B7280"))
        XCTAssertFalse(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#F97316"))
    }

    // MARK: - 双柱偏移封顶（2026-10-07 东林实报周粒度柱子对不上刻度）

    func testBarOffsetKeepsRatioOnNarrowMonthSlot() {
        // 月视图 30 桶 iPhone 槽 ≈10pt：比例偏移 0.20*10=2.0pt 未到封顶 2.35pt，沿用原比例
        let offset = ChartBarPairLayout.barOffsetUnits(pointCount: 30, slotWidthPt: 10)
        XCTAssertEqual(offset, 0.20, accuracy: 0.0001)
    }

    func testBarOffsetCapsOnWideMacWeekSlot() {
        // 周粒度 12 桶 Mac 槽 ≈79pt：比例偏移 14.2pt 会让柱子离刻度半格远，按柱宽+缝封顶
        let offset = ChartBarPairLayout.barOffsetUnits(pointCount: 12, slotWidthPt: 79)
        XCTAssertEqual(offset, 3.75 / 79, accuracy: 0.0001)
    }

    func testBarOffsetCapsOnIPhoneWeekSlot() {
        // 周粒度 12 桶 iPhone 槽 ≈29pt：比例偏移 5.2pt 同样超封顶
        let offset = ChartBarPairLayout.barOffsetUnits(pointCount: 12, slotWidthPt: 29)
        XCTAssertEqual(offset, 3.75 / 29, accuracy: 0.0001)
    }

    func testBarOffsetHonorsOverrideBarWidth() {
        // 年视图对照柱宽 5pt（不走分段默认值），封顶按 (5+1.5)/2 = 3.25pt
        let offset = ChartBarPairLayout.barOffsetUnits(pointCount: 12, slotWidthPt: 79, barWidth: 5)
        XCTAssertEqual(offset, 3.25 / 79, accuracy: 0.0001)
    }

    func testBarOffsetFallsBackToRatioWhenSlotUnknown() {
        XCTAssertEqual(ChartBarPairLayout.barOffsetUnits(pointCount: 12, slotWidthPt: 0), 0.18)
    }

    func testBarWidthSegmentsByPointCount() {
        XCTAssertEqual(ChartBarPairLayout.barWidth(pointCount: 12), 6)
        XCTAssertEqual(ChartBarPairLayout.barWidth(pointCount: 30), 3.2)
    }

    func testEstimatedSlotWidthSubtractsAxisGutter() {
        XCTAssertEqual(
            ChartBarPairLayout.estimatedSlotWidthPt(containerWidthPt: 402, pointCount: 12),
            (402 - 56) / 12,
            accuracy: 0.001
        )
    }
}
