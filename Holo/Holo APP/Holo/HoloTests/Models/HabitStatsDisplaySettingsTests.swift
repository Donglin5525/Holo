//
//  HabitStatsDisplaySettingsTests.swift
//  HoloTests
//
//  统计页展示设置持久化测试
//

import XCTest
@testable import Holo

final class HabitStatsDisplaySettingsTests: XCTestCase {

    // MARK: - Visible Habit IDs

    func testSaveVisibleHabitIdsRoundTrips() {
        let defaults = UserDefaults(suiteName: "HabitStatsDisplaySettingsTests")!
        defaults.removePersistentDomain(forName: "HabitStatsDisplaySettingsTests")
        let first = UUID()
        let second = UUID()
        let settings = HabitStatsDisplaySettings(userDefaults: defaults)

        settings.setVisibleHabitIds([first, second])

        XCTAssertEqual(settings.visibleHabitIds, [first, second])
    }

    func testEmptyVisibleHabitIdsWhenNoneSaved() {
        let defaults = UserDefaults(suiteName: "HabitStatsDisplaySettingsEmptyTests")!
        defaults.removePersistentDomain(forName: "HabitStatsDisplaySettingsEmptyTests")

        let settings = HabitStatsDisplaySettings(userDefaults: defaults)

        XCTAssertTrue(settings.visibleHabitIds.isEmpty)
    }

    // MARK: - Ordered Habit IDs

    func testOrderedHabitIdsRoundTrips() {
        let defaults = UserDefaults(suiteName: "HabitStatsDisplaySettingsOrderTests")!
        defaults.removePersistentDomain(forName: "HabitStatsDisplaySettingsOrderTests")
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let settings = HabitStatsDisplaySettings(userDefaults: defaults)

        settings.setOrderedHabitIds([a, b, c])

        XCTAssertEqual(settings.orderedHabitIds, [a, b, c])
    }

    // MARK: - Move Habit

    func testMoveHabitReordersIds() {
        let defaults = UserDefaults(suiteName: "HabitStatsDisplaySettingsMoveTests")!
        defaults.removePersistentDomain(forName: "HabitStatsDisplaySettingsMoveTests")
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let settings = HabitStatsDisplaySettings(userDefaults: defaults)
        settings.setOrderedHabitIds([a, b, c])

        settings.moveHabit(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(settings.orderedHabitIds, [b, c, a])
    }

    func testMoveHabitPersisted() {
        let suiteName = "HabitStatsDisplaySettingsMovePersistTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let a = UUID()
        let b = UUID()
        let settings = HabitStatsDisplaySettings(userDefaults: defaults)
        settings.setOrderedHabitIds([a, b])

        settings.moveHabit(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        // 重新加载验证持久化
        let reloaded = HabitStatsDisplaySettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.orderedHabitIds, [b, a])
    }
}
