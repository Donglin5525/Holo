//
//  AmountMathTests.swift
//  HoloTests
//
//  计算键盘求值器回归：从 AddTransactionSheet 迁到通用组件 AmountMath 后
//  行为零变化（四则运算/优先级/两位小数/除零/无运算符原样）。
//

import XCTest
@testable import Holo

final class AmountMathTests: XCTestCase {

    // MARK: - resolve（键盘 ✓ / 保存前求值入口）

    func test_resolve_basicArithmetic() {
        XCTAssertEqual(AmountMath.resolve("100-30"), "70")
        XCTAssertEqual(AmountMath.resolve("50+50"), "100")
        XCTAssertEqual(AmountMath.resolve("10×3"), "30")
        XCTAssertEqual(AmountMath.resolve("10÷4"), "2.5")
    }

    func test_resolve_operatorPrecedence() {
        XCTAssertEqual(AmountMath.resolve("2+3×4"), "14", "先乘除后加减")
        XCTAssertEqual(AmountMath.resolve("10-4÷2"), "8")
    }

    func test_resolve_roundsToTwoDecimals() {
        XCTAssertEqual(AmountMath.resolve("10÷3"), "3.33", "四舍五入两位小数")
        XCTAssertEqual(AmountMath.resolve("1.111+2.222"), "3.33")
    }

    func test_resolve_plainNumberUntouched() {
        XCTAssertEqual(AmountMath.resolve("88"), "88", "无运算符不求值")
        XCTAssertEqual(AmountMath.resolve("88.50"), "88.50")
        XCTAssertEqual(AmountMath.resolve("0"), "0")
    }

    func test_resolve_invalidExpression() {
        XCTAssertEqual(AmountMath.resolve("10÷0"), "10÷0", "除零求值失败保留原串")
        // 残缺表达式（如单 "+"）按 0 求值：迁移前既有行为（Double("+") ?? 0），保持不变
        XCTAssertEqual(AmountMath.resolve("+"), "0")
    }

    // MARK: - format

    func test_format_roundsToTwoDecimals() {
        XCTAssertEqual(AmountMath.format(Decimal(string: "3.335")!), "3.34")
        XCTAssertEqual(AmountMath.format(Decimal(string: "3.334")!), "3.33")
        XCTAssertEqual(AmountMath.format(Decimal(string: "70")!), "70")
    }

    // MARK: - containsOperator

    func test_containsOperator() {
        XCTAssertTrue(AmountMath.containsOperator("100-30"))
        XCTAssertTrue(AmountMath.containsOperator("10÷3"))
        XCTAssertFalse(AmountMath.containsOperator("100.50"))
        XCTAssertFalse(AmountMath.containsOperator(""))
    }
}
