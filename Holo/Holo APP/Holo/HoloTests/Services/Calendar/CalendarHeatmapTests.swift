//
//  CalendarHeatmapTests.swift
//  HoloTests
//
//  月历色阶纯函数单测：事件数 → 等级映射（边界值）
//

import XCTest
@testable import Holo

final class CalendarHeatmapTests: XCTestCase {

    func test_零条为空档等级0() {
        XCTAssertEqual(CalendarHeatmap.level(forCount: 0), 0)
    }

    func test_1到2条为等级1() {
        XCTAssertEqual(CalendarHeatmap.level(forCount: 1), 1)
        XCTAssertEqual(CalendarHeatmap.level(forCount: 2), 1)
    }

    func test_3到5条为等级2() {
        XCTAssertEqual(CalendarHeatmap.level(forCount: 3), 2)
        XCTAssertEqual(CalendarHeatmap.level(forCount: 5), 2)
    }

    func test_6到9条为等级3() {
        XCTAssertEqual(CalendarHeatmap.level(forCount: 6), 3)
        XCTAssertEqual(CalendarHeatmap.level(forCount: 9), 3)
    }

    func test_10条及以上为等级4() {
        XCTAssertEqual(CalendarHeatmap.level(forCount: 10), 4)
        XCTAssertEqual(CalendarHeatmap.level(forCount: 100), 4)
    }

    func test_单条记录非空档色() {
        // 月历区别于热力图：1 条记录就应有色（非空档 #F5F2ED）
        let zeroColor = CalendarHeatmap.color(forCount: 0)
        let oneColor = CalendarHeatmap.color(forCount: 1)
        XCTAssertNotEqual(zeroColor, oneColor, "1 条记录的色应区别于 0 条空档")
    }
}
