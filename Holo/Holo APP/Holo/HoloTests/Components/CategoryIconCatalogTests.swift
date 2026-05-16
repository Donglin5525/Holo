//
//  CategoryIconCatalogTests.swift
//  HoloTests
//
//  图标目录自动化校验测试
//  覆盖：符号可解析、旧图标保留、无重复、分组结构
//

import XCTest
import UIKit
@testable import Holo

final class CategoryIconCatalogTests: XCTestCase {

    // MARK: - 1. 所有 SF Symbol 可解析

    /// 遍历全部 SF Symbol 图标，校验 UIImage(systemSymbolName:) != nil
    func testAllSymbolsResolvable() {
        var failures: [String] = []

        for iconName in CategoryIconCatalog.sfSymbolIcons {
            let isAvailable = UIImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil
            if !isAvailable {
                failures.append(iconName)
            }
        }

        if !failures.isEmpty {
            XCTFail("以下 \(failures.count) 个图标无法解析：\n\(failures.joined(separator: ", "))")
        }
    }

    // MARK: - 2. 旧版 88 个预设图标全部保留

    /// 确保当前 88 个基线图标全部包含在新 catalog 中
    func testLegacyPresetIconsStillIncluded() {
        let allIconsSet = Set(CategoryIconCatalog.allIcons)
        var missing: [String] = []

        for legacy in CategoryIconCatalog.legacyPresetIcons {
            if !allIconsSet.contains(legacy) {
                missing.append(legacy)
            }
        }

        if !missing.isEmpty {
            XCTFail("以下 \(missing.count) 个旧版图标丢失：\n\(missing.joined(separator: ", "))")
        }
    }

    // MARK: - 3. 图标无重复

    /// 确保 allIcons 去重后数量与预期一致
    func testNoDuplicateIconsAcrossCatalog() {
        let allIcons = CategoryIconCatalog.allIcons
        let uniqueIcons = Set(allIcons)

        XCTAssertEqual(
            allIcons.count,
            uniqueIcons.count,
            "图标目录中存在重复项，总数 \(allIcons.count) vs 去重后 \(uniqueIcons.count)"
        )
    }

    // MARK: - 4. 分组数量正确

    /// 确保 12 个展示分组存在
    func testSectionCount() {
        XCTAssertEqual(
            CategoryIconCatalog.sections.count,
            12,
            "展示分组数量应为 12"
        )
    }

    // MARK: - 5. 总图标数量在合理范围

    /// 确保图标总数接近方案目标（约 171 个）
    func testTotalIconCount() {
        let count = CategoryIconCatalog.allIcons.count
        XCTAssertGreaterThanOrEqual(count, 165, "图标总数应不少于 165")
        XCTAssertLessThanOrEqual(count, 180, "图标总数应不超过 180")
    }

    // MARK: - 6. 每个 section 有图标

    /// 确保每个展示分组至少有一个图标
    func testEverySectionHasIcons() {
        for section in CategoryIconCatalog.sections {
            XCTAssertFalse(
                section.icons.isEmpty,
                "展示分组「\(section.title)」(\(section.id)) 不应为空"
            )
        }
    }

    // MARK: - 7. 自绘兜底图标进入目录但不按 SF Symbol 校验

    func testCustomFallbackIconsAreAvailableInCatalog() {
        let customIcons = CategoryIconCatalog.customIconNames

        XCTAssertTrue(customIcons.contains("holo.category.generic"))
        XCTAssertTrue(customIcons.contains("holo.category.misc"))

        for iconName in customIcons {
            XCTAssertTrue(CategoryIconCatalog.contains(iconName), "自绘图标 \(iconName) 应出现在图标目录中")
            XCTAssertFalse(CategoryIconCatalog.sfSymbolIcons.contains(iconName), "自绘图标 \(iconName) 不应进入 SF Symbol 校验列表")
        }
    }

    // MARK: - 8. 轻量增强科目需要有可选图标

    func testLightweightFinanceExpansionIconsAreInCatalog() {
        let expectedIcons = [
            "bolt.car.fill",
            "car.rear.waves.up.fill",
            "wrench.and.screwdriver.fill",
            "exclamationmark.triangle.fill",
            "shippingbox.fill",
            "dollarsign.arrow.circlepath",
            "building.columns.circle.fill",
            "figure.and.child.holdinghands",
            "person.2.badge.gearshape.fill",
            "shippingbox.and.arrow.backward.fill",
            "cloud.fill",
            "laptopcomputer",
            "sparkles",
            "bed.double.fill",
            "ticket.fill",
            "briefcase.fill",
            "doc.text.fill",
            "person.crop.circle.badge.checkmark",
            "giftcard.fill",
            "arrow.uturn.backward.circle.fill",
        ]

        for iconName in expectedIcons {
            XCTAssertTrue(CategoryIconCatalog.contains(iconName), "新增科目图标 \(iconName) 应在图标目录中可选")
        }
    }
}
