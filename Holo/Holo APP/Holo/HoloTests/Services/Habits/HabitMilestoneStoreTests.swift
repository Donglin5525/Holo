//
//  HabitMilestoneStoreTests.swift
//  HoloTests
//
//  2026-10 重构里程碑账本验证（方案 §9.4/R25/R26）：
//  阈值按真实单位、去重键四要素、去重持久化、重复展示拦截。
//

import XCTest
@testable import Holo

@MainActor
final class HabitMilestoneStoreTests: XCTestCase {

    /// iOS 26.3 模拟器 hosted XCTest 中销毁局部 ObservableObject/带运行时元数据的
    /// 对象会非法释放（malloc: pointer being freed was not allocated，2026-10-06 实测）；
    /// 与 HabitStatsDisplaySettingsTests 同款解法：保留到测试进程结束。
    private static var retainedStores: [HabitMilestoneStore] = []

    private func makeStore(defaults: UserDefaults) -> HabitMilestoneStore {
        let store = HabitMilestoneStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        // 新随机 suite 天然为空；不调用 removePersistentDomain
        // （该调用在测试宿主触发 malloc 崩溃，2026-10-06 实测在档）
        let suiteName = "HabitMilestoneTest.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func streak(_ value: Int, unit: HabitStreakUnit, kind: String) -> HabitStreakLabel {
        HabitStreakLabel(value: value, unitName: unit.displayName, kindName: kind)
    }

    // MARK: - 阈值表（R25）

    func test_每日里程碑阈值7_30_100天() {
        let definitions = HabitMilestoneStore.definitions(for: .daily)
        XCTAssertEqual(definitions.map(\.threshold), [7, 30, 100])
        XCTAssertTrue(definitions.allSatisfy { $0.unit == .day }, "每日单位是天，不折算周月")
    }

    func test_每周里程碑阈值4_12_52周() {
        let definitions = HabitMilestoneStore.definitions(for: .weekly)
        XCTAssertEqual(definitions.map(\.threshold), [4, 12, 52])
        XCTAssertTrue(definitions.allSatisfy { $0.unit == .week })
    }

    func test_每月里程碑阈值3_6_12月() {
        let definitions = HabitMilestoneStore.definitions(for: .monthly)
        XCTAssertEqual(definitions.map(\.threshold), [3, 6, 12])
        XCTAssertTrue(definitions.allSatisfy { $0.unit == .month })
    }

    // MARK: - 达成与去重键

    func test_达成判定按单位匹配() throws {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        let habitId = UUID()

        // 连续 7 天（每日）
        let achieved = store.achievedMilestones(habitId: habitId,
                                                streak: streak(7, unit: .day, kind: String(localized: "连续达标")),
                                                frequency: .daily)
        XCTAssertEqual(achieved.count, 1)
        XCTAssertEqual(achieved.first?.threshold, 7)

        // 连续 6 天：无里程碑
        let none = store.achievedMilestones(habitId: habitId,
                                            streak: streak(6, unit: .day, kind: String(localized: "连续达标")),
                                            frequency: .daily)
        XCTAssertTrue(none.isEmpty, "未达阈值不显示假徽章")
    }

    func test_去重键四要素() {
        let habitA = UUID()
        let habitB = UUID()
        let keyA = HabitMilestoneStore.key(habitId: habitA, kindName: "连续达标", unit: .day, threshold: 7)
        let keyAgain = HabitMilestoneStore.key(habitId: habitA, kindName: "连续达标", unit: .day, threshold: 7)
        let keyDifferentThreshold = HabitMilestoneStore.key(habitId: habitA, kindName: "连续达标", unit: .day, threshold: 30)
        let keyDifferentHabit = HabitMilestoneStore.key(habitId: habitB, kindName: "连续达标", unit: .day, threshold: 7)
        let keyDifferentKind = HabitMilestoneStore.key(habitId: habitA, kindName: "连续记录", unit: .day, threshold: 7)
        let keyDifferentUnit = HabitMilestoneStore.key(habitId: habitA, kindName: "连续达标", unit: .week, threshold: 7)

        XCTAssertEqual(keyA, keyAgain, "同键去重")
        XCTAssertNotEqual(keyA, keyDifferentThreshold)
        XCTAssertNotEqual(keyA, keyDifferentHabit)
        XCTAssertNotEqual(keyA, keyDifferentKind)
        XCTAssertNotEqual(keyA, keyDifferentUnit)
    }

    // MARK: - 去重持久化（R26）

    func test_标记后跨实例不重复展示() throws {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        let habitId = UUID()
        let achieved = store.achievedMilestones(habitId: habitId,
                                                streak: streak(30, unit: .day, kind: String(localized: "连续达标")),
                                                frequency: .daily)
        let milestone = try XCTUnwrap(achieved.last)

        XCTAssertFalse(store.isDisplayed(milestone))
        store.markDisplayed(milestone)
        XCTAssertTrue(store.isDisplayed(milestone))

        // 重启（新实例同 defaults）后仍视为已展示：不因重启重复播放
        let freshStore = makeStore(defaults: defaults)
        XCTAssertTrue(freshStore.isDisplayed(milestone), "去重账本本机持久化")
    }

    func test_不同习惯互不影响() throws {
        let defaults = makeIsolatedDefaults()
        let store = makeStore(defaults: defaults)
        let habitA = UUID()
        let habitB = UUID()

        let milestoneA = try XCTUnwrap(store.achievedMilestones(habitId: habitA,
                                                                streak: streak(7, unit: .day, kind: String(localized: "连续达标")),
                                                                frequency: .daily).last)
        let milestoneB = try XCTUnwrap(store.achievedMilestones(habitId: habitB,
                                                                streak: streak(7, unit: .day, kind: String(localized: "连续达标")),
                                                                frequency: .daily).last)

        store.markDisplayed(milestoneA)
        XCTAssertTrue(store.isDisplayed(milestoneA))
        XCTAssertFalse(store.isDisplayed(milestoneB), "每个习惯独立首播")
    }
}
