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
}
