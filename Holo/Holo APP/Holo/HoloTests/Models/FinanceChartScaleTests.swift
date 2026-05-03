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

        XCTAssertEqual(scale.amountAxisMax, 414)
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
        XCTAssertEqual(scale.amountAxisMax, 230)
        XCTAssertEqual(scale.balanceAxisMin, -5_000)
        XCTAssertEqual(scale.balanceAxisMax, 5_000)
        XCTAssertEqual(scale.scaledBalance(-5_000), 0, accuracy: 0.001)
        XCTAssertEqual(scale.scaledBalance(0), 115, accuracy: 0.001)
        XCTAssertEqual(scale.scaledBalance(5_000), 230, accuracy: 0.001)
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
}
