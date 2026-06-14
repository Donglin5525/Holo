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
            "chart.line.uptrend.xyaxis"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "交通", type: .expense, parentName: nil),
            "car.fill"
        )
    }

    func testSubCategoryDefaultIconLookupUsesParentNameToDisambiguate() {
        XCTAssertEqual(
            Category.defaultIconName(name: "早餐", type: .expense, parentName: "餐饮"),
            "holo.category.breakfast"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "午餐", type: .expense, parentName: "餐饮"),
            "holo.category.lunch"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "晚餐", type: .expense, parentName: "餐饮"),
            "holo.category.dinner"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "水果", type: .expense, parentName: "餐饮"),
            "holo.category.fruit"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "基金", type: .income, parentName: "投资理财"),
            "chart.pie.fill"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "礼物", type: .income, parentName: "人情来往"),
            "gift.fill"
        )
        XCTAssertEqual(
            Category.defaultIconName(name: "礼物", type: .expense, parentName: "购物"),
            "gift.fill"
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
