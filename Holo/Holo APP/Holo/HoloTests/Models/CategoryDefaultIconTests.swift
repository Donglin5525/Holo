//
//  CategoryDefaultIconTests.swift
//  HoloTests
//
//  分类默认图标恢复逻辑测试
//

import XCTest
@testable import Holo

final class CategoryDefaultIconTests: XCTestCase {

    func testTopLevelDefaultIconLookup() {
        XCTAssertEqual(
            Category.defaultIconName(name: "投资理财", type: .income, parentName: nil),
            "cat_inc_invest"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "交通", type: .expense, parentName: nil),
            "cat_transport"
        )
    }

    func testSubCategoryDefaultIconLookupUsesParentNameToDisambiguate() {
        XCTAssertEqual(
            Category.defaultIconName(name: "早餐", type: .expense, parentName: "餐饮"),
            "finance_breakfast"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "午餐", type: .expense, parentName: "餐饮"),
            "finance_lunch"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "晚餐", type: .expense, parentName: "餐饮"),
            "finance_dinner"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "水果", type: .expense, parentName: "餐饮"),
            "finance_fruit"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "基金", type: .income, parentName: "投资理财"),
            "income_fund"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "礼物", type: .income, parentName: "人情来往"),
            "income_gift_in"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "礼物", type: .expense, parentName: "购物"),
            "finance_gift"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "其他", type: .expense, parentName: "人情"),
            "ellipsis.circle.fill"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "其他", type: .expense, parentName: "其他"),
            "questionmark.folder.fill"
        )
    }

    func testUnknownDefaultIconReturnsNil() {
        XCTAssertNil(Category.defaultIconName(name: "不存在", type: .expense, parentName: nil))
        XCTAssertNil(Category.defaultIconName(name: "基金", type: .expense, parentName: "投资理财"))
    }
}
