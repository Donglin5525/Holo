//
//  HabitStatsDisplaySettingsTests.swift
//  HoloTests
//
//  统计页展示设置持久化测试
//

import XCTest
@testable import Holo

final class HabitStatsDisplaySettingsTests: XCTestCase {

    /// iOS 26.3 Simulator 在 hosted XCTest 中销毁局部 @Published 对象会非法释放；
    /// 生产对象本身是长生命周期单例，这里同样保留到测试进程结束。
    private static var retainedSettings: [HabitStatsDisplaySettings] = []

    private func makeDefaults(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: "com.holo.tests.\(label).\(UUID().uuidString)")!
    }

    private func makeSettings(_ defaults: UserDefaults) -> HabitStatsDisplaySettings {
        let settings = HabitStatsDisplaySettings(userDefaults: defaults)
        Self.retainedSettings.append(settings)
        return settings
    }

    // MARK: - Visible Habit IDs

    func testSaveVisibleHabitIdsRoundTrips() {
        let defaults = makeDefaults("visible")
        let first = UUID()
        let second = UUID()
        let settings = makeSettings(defaults)

        settings.setVisibleHabitIds([first, second])

        XCTAssertEqual(settings.visibleHabitIds, [first, second])
    }

    func testEmptyVisibleHabitIdsWhenNoneSaved() {
        let defaults = makeDefaults("empty")

        let settings = makeSettings(defaults)

        XCTAssertTrue(settings.visibleHabitIds.isEmpty)
    }

    // MARK: - Ordered Habit IDs

    func testOrderedHabitIdsRoundTrips() {
        let defaults = makeDefaults("order")
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let settings = makeSettings(defaults)

        settings.setOrderedHabitIds([a, b, c])

        XCTAssertEqual(settings.orderedHabitIds, [a, b, c])
    }

    // MARK: - Move Habit

    func testMoveHabitReordersIds() {
        let defaults = makeDefaults("move")
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let settings = makeSettings(defaults)
        settings.setOrderedHabitIds([a, b, c])

        settings.moveHabit(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(settings.orderedHabitIds, [b, c, a])
    }

    func testMoveHabitPersisted() {
        let defaults = makeDefaults("move-persist")
        let a = UUID()
        let b = UUID()
        let settings = makeSettings(defaults)
        settings.setOrderedHabitIds([a, b])

        settings.moveHabit(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        // 重新加载验证持久化
        let reloaded = makeSettings(defaults)
        XCTAssertEqual(reloaded.orderedHabitIds, [b, a])
    }
}
