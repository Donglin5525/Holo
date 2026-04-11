//
//  CategorySFSymbolMapperTests.swift
//  HoloTests
//
//  测试分类名称到 SF Symbol 图标的映射
//

import XCTest
@testable import Holo

final class CategorySFSymbolMapperTests: XCTestCase {

    // MARK: - 二级分类映射

    func testSubCategoryIcon() {
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "餐饮", subCategory: "午餐"), "sun.max.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "交通", subCategory: "打车"), "car.side.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "购物", subCategory: "数码"), "desktopcomputer")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "居住", subCategory: "房租"), "key.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "医疗", subCategory: "就医"), "stethoscope")
    }

    // MARK: - 一级分类回退

    func testPrimaryCategoryFallback() {
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "餐饮", subCategory: nil), "fork.knife")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "交通", subCategory: nil), "car.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "购物", subCategory: nil), "bag.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "娱乐", subCategory: nil), "music.note.list")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "居住", subCategory: nil), "house.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "医疗", subCategory: nil), "heart.text.square.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "学习", subCategory: nil), "book.closed.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "人情", subCategory: nil), "yensign.circle.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "其他", subCategory: nil), "questionmark.folder.fill")
    }

    // MARK: - 收入分类

    func testIncomeCategoryIcons() {
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "工资收入", subCategory: nil), "banknote.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "投资理财", subCategory: nil), "chart.line.uptrend.xyaxis")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "工资收入", subCategory: "工资"), "banknote.fill")
        XCTAssertEqual(CategorySFSymbolMapper.icon(for: "投资理财", subCategory: "股票"), "chart.line.uptrend.xyaxis")
    }

    // MARK: - 未知分类回退

    func testUnknownCategoryFallback() {
        let icon = CategorySFSymbolMapper.icon(for: nil, subCategory: nil)
        XCTAssertEqual(icon, "yensign.circle", "未知分类应回退到默认图标")
    }

    func testUnknownSubCategoryFallback() {
        let icon = CategorySFSymbolMapper.icon(for: "餐饮", subCategory: "不存在的子分类")
        XCTAssertEqual(icon, "fork.knife", "未知子分类应回退到一级分类图标")
    }

    // MARK: - SF Symbol 存在性验证

    /// 验证映射表中所有 SF Symbol 名称在当前系统上确实存在
    func testAllMappedSFSymbolsExist() {
        let testCases: [(String?, String?)] = [
            // 二级分类
            ("餐饮", "午餐"), ("餐饮", "咖啡"), ("交通", "地铁"), ("交通", "打车"),
            ("购物", "服饰"), ("娱乐", "电影"), ("居住", "房租"), ("医疗", "就医"),
            ("学习", "课程"), ("人情", "红包礼金"), ("其他", "社交"),
            ("工资收入", "工资"), ("投资理财", "股票"),
            // 一级分类
            ("餐饮", nil), ("交通", nil), ("购物", nil), ("娱乐", nil),
            ("居住", nil), ("医疗", nil), ("学习", nil), ("人情", nil),
            ("其他", nil), ("工资收入", nil), ("投资理财", nil),
            // 未知
            (nil, nil), ("不存在的分类", nil),
        ]

        for (primary, sub) in testCases {
            let iconName = CategorySFSymbolMapper.icon(for: primary, subCategory: sub)
            // NSImage 在 iOS 上不可用，使用 UIImage
            #if os(iOS)
            let symbolExists = UIImage(systemName: iconName) != nil
            #else
            let symbolExists = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil
            #endif
            XCTAssertTrue(symbolExists, "SF Symbol '\(iconName)' (primary=\(primary ?? "nil"), sub=\(sub ?? "nil")) 不存在")
        }
    }

    // MARK: - 卡片固定图标存在性

    func testFixedCardIconsExist() {
        let fixedIcons = [
            "checkmark.circle",    // 任务卡片
            "flame.fill",          // 习惯打卡卡片
            "heart.fill",          // 心情卡片
            "scalemass.fill",      // 体重卡片
            "sparkles",            // 通用确认卡片
            "fork.knife",          // 餐饮
            "car.fill",            // 交通
        ]

        for iconName in fixedIcons {
            #if os(iOS)
            let symbolExists = UIImage(systemName: iconName) != nil
            #else
            let symbolExists = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil
            #endif
            XCTAssertTrue(symbolExists, "SF Symbol '\(iconName)' 不存在")
        }
    }
}
