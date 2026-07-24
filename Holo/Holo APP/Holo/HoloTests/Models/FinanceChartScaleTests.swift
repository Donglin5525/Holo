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

    func testPieChartUsesChartPaletteForImportedPlaceholderGrayCategories() {
        XCTAssertTrue(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#64748B"))
        XCTAssertTrue(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#6B7280"))
        XCTAssertFalse(FinanceCategoryChartColor.shouldUseChartPalette(hex: "#F97316"))
    }
}
