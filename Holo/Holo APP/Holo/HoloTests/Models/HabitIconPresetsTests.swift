//
//  HabitIconPresetsTests.swift
//  HoloTests
//
//  统一图标精选目录（UnifiedIconCatalog）校验。
//  文件名沿用历史（HabitIconPresets 已退役并入统一目录），避免为改名动 pbxproj。
//

import XCTest
import UIKit
@testable import Holo

final class UnifiedIconCatalogTests: XCTestCase {

    func testCatalogSizeWithinLimitAndUnique() {
        let names = UnifiedIconCatalog.allNames
        XCTAssertLessThanOrEqual(names.count, 120, "精选集上限 120，当前 \(names.count)")
        XCTAssertEqual(names.count, Set(names).count, "精选集内存在重复图标名")
    }

    func testAllSFSymbolsResolvable() {
        let failures = UnifiedIconCatalog.sections
            .flatMap(\.items)
            .filter { !$0.isAsset }
            .compactMap { UIImage(systemName: $0.name) == nil ? $0.name : nil }

        XCTAssertTrue(failures.isEmpty, "以下 SF Symbol 无法解析：\(failures.joined(separator: ", "))")
    }

    func testSectionHeaderSymbolsResolvable() {
        let failures = UnifiedIconCatalog.sections
            .compactMap { UIImage(systemName: $0.icon) == nil ? $0.icon : nil }

        XCTAssertTrue(failures.isEmpty, "以下分组标题图标无法解析：\(failures.joined(separator: ", "))")
    }

    func testAllAssetIconsExistInBundle() {
        let assets = UnifiedIconCatalog.sections.flatMap(\.items).filter(\.isAsset)
        XCTAssertFalse(assets.isEmpty, "精选集应包含自绘资产")

        let failures = assets.compactMap { item -> String? in
            UIImage(named: item.name, in: Bundle(for: UnifiedIconCatalogTests.self), compatibleWith: nil) == nil
                && UIImage(named: item.name) == nil
                ? item.name : nil
        }
        XCTAssertTrue(failures.isEmpty, "以下资产不在 Asset Catalog：\(failures.joined(separator: ", "))")
        XCTAssertTrue(assets.allSatisfy { UnifiedIconCatalog.isAssetIcon($0.name) }, "资产条目必须被前缀识别为资产")
    }

    func testAssetPrefixRecognitionCoversLegacyNames() {
        // 存量数据里的历史资产（不在精选 120 内）仍要按资产渲染
        XCTAssertTrue(UnifiedIconCatalog.isAssetIcon("finance_movie"))
        XCTAssertTrue(UnifiedIconCatalog.isAssetIcon("income_salary"))
        XCTAssertTrue(UnifiedIconCatalog.isAssetIcon("cat_food"))
        XCTAssertTrue(UnifiedIconCatalog.isAssetIcon("habit_nosmoking"))
        XCTAssertFalse(UnifiedIconCatalog.isAssetIcon("figure.run"))
        XCTAssertFalse(UnifiedIconCatalog.isAssetIcon("🏃"))
    }

    func testKeyHabitSemanticsPreserved() {
        // 习惯侧迁移前的语义保底：感恩/减少/戒烟三个曾被专项校验的图标仍在精选集
        XCTAssertEqual(UnifiedIconCatalog.iconName(for: "感恩"), "heart.text.square.fill")
        XCTAssertEqual(UnifiedIconCatalog.iconName(for: "减少"), "minus.circle.fill")
        XCTAssertEqual(UnifiedIconCatalog.iconName(for: "戒烟"), "habit_nosmoking")
    }
}

private extension UnifiedIconCatalog {
    static func iconName(for label: String) -> String? {
        sections.flatMap(\.items).first { $0.label == label }?.name
    }
}
