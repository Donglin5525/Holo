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

    // MARK: - 显式全部关闭兼容（2026-10 重构，方案 §12.4 / R42/R43）

    func testLegacyEmptyMeansAllWhenNotConfigured() {
        let defaults = makeDefaults("legacy-empty")
        let settings = makeSettings(defaults)
        // 未配置过：空数组保持旧语义 = 显示全部（nil）
        XCTAssertNil(settings.effectiveStatsVisibleIds())
        XCTAssertNil(settings.effectiveDashboardVisibleIds())
    }

    func testExplicitEmptyMeansAllClosedAfterConfigured() {
        let defaults = makeDefaults("explicit-empty")
        let settings = makeSettings(defaults)

        settings.setVisibleHabitIds([])
        XCTAssertTrue(settings.effectiveStatsVisibleIds()?.isEmpty == true, "已配置后空数组 = 全部关闭")
    }

    func testDashboardExplicitClosedDoesNotAutoAddNewHabit() {
        let defaults = makeDefaults("dashboard-closed")
        let settings = makeSettings(defaults)
        settings.setDashboardVisibleHabitIds([])

        let newHabit = UUID()
        settings.addDashboardHabitIfNeeded(newHabit)
        XCTAssertTrue(settings.effectiveDashboardVisibleIds()?.isEmpty == true, "显式全关闭时新建习惯不擅自开启")
    }

    func testDashboardConfiguredKeepsAutoAddForNonEmptyWhitelist() {
        let defaults = makeDefaults("dashboard-open")
        let settings = makeSettings(defaults)
        let existing = UUID()
        settings.setDashboardVisibleHabitIds([existing])

        let newHabit = UUID()
        settings.addDashboardHabitIfNeeded(newHabit)
        XCTAssertEqual(settings.dashboardVisibleHabitIds, [existing, newHabit], "非空白名单自动纳入保持")
    }
}

