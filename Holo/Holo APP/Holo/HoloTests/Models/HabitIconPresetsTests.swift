//
//  HabitIconPresetsTests.swift
//  HoloTests
//
//  习惯预设图标语义校验
//

import XCTest
import UIKit
@testable import Holo

final class HabitIconPresetsTests: XCTestCase {

    func testGratitudeAndReduceUseSemanticIcons() {
        XCTAssertEqual(HabitIconPresets.iconName(for: "感恩"), "heart.text.square.fill")
        XCTAssertEqual(HabitIconPresets.iconName(for: "减少"), "minus.circle.fill")
    }

    func testExpandedHabitPresetIconsAreAvailable() {
        let expectedLabels = [
            "呼吸", "拉伸", "护眼", "站立",
            "编程", "日记", "数据复盘", "打卡计划",
            "控制", "少刷短视频", "减少咖啡因",
        ]

        for label in expectedLabels {
            XCTAssertNotNil(HabitIconPresets.iconName(for: label), "习惯预设应包含「\(label)」")
        }
    }

    func testAllHabitPresetSymbolsResolvable() {
        let failures = HabitIconPresets.allItems.compactMap { item -> String? in
            guard !item.isCustom else { return nil }
            return UIImage(systemName: item.name) == nil ? item.name : nil
        }

        XCTAssertTrue(failures.isEmpty, "以下习惯图标无法解析：\(failures.joined(separator: ", "))")
    }
}

private extension HabitIconPresets {
    static func iconName(for label: String) -> String? {
        allItems.first { $0.label == label }?.name
    }
}
