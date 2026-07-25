//
//  HorizontalGestureLockTests.swift
//  HoloTests
//
//  横向手势方向锁定测试
//

import XCTest
@testable import Holo

final class HorizontalGestureLockTests: XCTestCase {

    func testSmallMovementStaysUndecided() {
        var lock = HorizontalGestureLock()

        XCTAssertEqual(lock.update(translation: CGSize(width: 5, height: 4)), .undecided)
        XCTAssertEqual(lock.axis, .undecided)
    }

    func testHorizontalMovementLocksWhenClearlyDominant() {
        var lock = HorizontalGestureLock()

        XCTAssertEqual(lock.update(translation: CGSize(width: -12, height: 9)), .horizontal)
        XCTAssertEqual(lock.axis, .horizontal)
    }

    func testVerticalMovementLocksAndDoesNotFlipBackToHorizontal() {
        var lock = HorizontalGestureLock()

        XCTAssertEqual(lock.update(translation: CGSize(width: 7, height: 12)), .vertical)
        XCTAssertEqual(lock.update(translation: CGSize(width: 40, height: 13)), .vertical)
    }

    func testHorizontalMovementDoesNotFlipToVerticalAfterLocking() {
        var lock = HorizontalGestureLock()

        XCTAssertEqual(lock.update(translation: CGSize(width: -18, height: 4)), .horizontal)
        XCTAssertEqual(lock.update(translation: CGSize(width: -24, height: 28)), .horizontal)
    }

    func testDiagonalMovementWaitsForClearIntent() {
        var lock = HorizontalGestureLock()

        XCTAssertEqual(lock.update(translation: CGSize(width: 11, height: 10)), .undecided)
        XCTAssertEqual(lock.update(translation: CGSize(width: 18, height: 10)), .horizontal)
    }

    func testChartPanAcceptsClearlyHorizontalIntent() {
        XCTAssertTrue(
            ChartGestureArbitration.shouldBeginHorizontalPan(
                velocity: CGPoint(x: 180, y: 70)
            )
        )
    }

    func testChartPanYieldsVerticalAndAmbiguousIntentToScrollView() {
        XCTAssertFalse(
            ChartGestureArbitration.shouldBeginHorizontalPan(
                velocity: CGPoint(x: 40, y: 160)
            )
        )
        XCTAssertFalse(
            ChartGestureArbitration.shouldBeginHorizontalPan(
                velocity: CGPoint(x: 100, y: 95)
            )
        )
    }

    func testChartPanNeverRecognizesSimultaneouslyWithPageScroll() {
        XCTAssertFalse(ChartGestureArbitration.allowsSimultaneousRecognition)
    }

    func testAmountSortReturnsToTimelineWhenChartNavigatesByDate() {
        XCTAssertEqual(
            FinanceDetailSortOrder.amountDescending.orderForChartNavigation,
            .timeDescending
        )
        XCTAssertEqual(
            FinanceDetailSortOrder.amountAscending.orderForChartNavigation,
            .timeDescending
        )
        XCTAssertEqual(
            FinanceDetailSortOrder.timeAscending.orderForChartNavigation,
            .timeAscending
        )
    }

    func testFinanceDetailAmountSortUsesDateAsStableTieBreaker() {
        let older = FinanceDetailSortValue(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            date: Date(timeIntervalSince1970: 100),
            amount: 50
        )
        let newer = FinanceDetailSortValue(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            date: Date(timeIntervalSince1970: 200),
            amount: 50
        )

        XCTAssertTrue(
            FinanceDetailSortOrder.amountDescending.areInIncreasingOrder(newer, older)
        )
        XCTAssertTrue(
            FinanceDetailSortOrder.amountAscending.areInIncreasingOrder(newer, older)
        )
    }

    func testFinanceDetailTimeSortSupportsBothDirections() {
        let older = FinanceDetailSortValue(
            id: UUID(),
            date: Date(timeIntervalSince1970: 100),
            amount: 10
        )
        let newer = FinanceDetailSortValue(
            id: UUID(),
            date: Date(timeIntervalSince1970: 200),
            amount: 20
        )

        XCTAssertTrue(
            FinanceDetailSortOrder.timeDescending.areInIncreasingOrder(newer, older)
        )
        XCTAssertTrue(
            FinanceDetailSortOrder.timeAscending.areInIncreasingOrder(older, newer)
        )
    }
}
