//
//  HabitStatsDisplaySettings.swift
//  Holo
//
//  统计页展示习惯的持久化配置
//  管理哪些习惯出现在统计页及其排序
//

import Foundation
import Combine

@MainActor
final class HabitStatsDisplaySettings: ObservableObject {

    // MARK: - Singleton

    static let shared = HabitStatsDisplaySettings()

    // MARK: - Published Properties

    @Published private(set) var visibleHabitIds: [UUID]
    @Published private(set) var orderedHabitIds: [UUID]
    @Published private(set) var dashboardVisibleHabitIds: [UUID]

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let visibleKey = "habit.stats.visible.ids"
    private let orderKey = "habit.stats.order.ids"
    private let dashboardVisibleKey = "habit.dashboard.visible.ids"
    /// 2026-10 重构：旧键空数组语义是「显示全部」，无法表达「全部关闭」。
    /// 用户主动保存过展示设置后写入配置标记，此后空数组 = 全部关闭。
    /// 无标记的存量用户完全走旧逻辑，零迁移。
    private let visibleConfiguredKey = "habit.stats.visibility.configured.v1"
    private let dashboardConfiguredKey = "habit.dashboard.visibility.configured.v1"

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.visibleHabitIds = Self.loadUUIDs(forKey: visibleKey, from: userDefaults)
        self.orderedHabitIds = Self.loadUUIDs(forKey: orderKey, from: userDefaults)
        self.dashboardVisibleHabitIds = Self.loadUUIDs(forKey: dashboardVisibleKey, from: userDefaults)
    }

    // MARK: - Public Methods

    func setVisibleHabitIds(_ ids: [UUID]) {
        visibleHabitIds = ids
        save(ids, forKey: visibleKey)
        userDefaults.set(true, forKey: visibleConfiguredKey)
    }

    func setOrderedHabitIds(_ ids: [UUID]) {
        orderedHabitIds = ids
        save(ids, forKey: orderKey)
    }

    func setDashboardVisibleHabitIds(_ ids: [UUID]) {
        dashboardVisibleHabitIds = ids
        save(ids, forKey: dashboardVisibleKey)
        userDefaults.set(true, forKey: dashboardConfiguredKey)
    }

    // MARK: - 有效展示集合（全关闭兼容的唯一出口）

    /// 统计展示的有效习惯集合。
    /// - Returns: nil = 显示全部（旧语义，新建习惯自然出现）；[] = 显式全部关闭；非空 = 指定集合。
    func effectiveStatsVisibleIds() -> [UUID]? {
        Self.effectiveIds(raw: visibleHabitIds, configured: userDefaults.bool(forKey: visibleConfiguredKey))
    }

    /// 今日看板的有效习惯集合。语义同上。
    func effectiveDashboardVisibleIds() -> [UUID]? {
        Self.effectiveIds(raw: dashboardVisibleHabitIds, configured: userDefaults.bool(forKey: dashboardConfiguredKey))
    }

    /// 兼容读取：未配置时维持旧「空数组=全部」；已配置后忠实呈现空数组。
    private static func effectiveIds(raw: [UUID], configured: Bool) -> [UUID]? {
        if configured { return raw }
        return raw.isEmpty ? nil : raw
    }

    /// 显式全部关闭时新建习惯不擅自开启；其余沿用既有「非空白名单自动纳入」。
    func addDashboardHabitIfNeeded(_ id: UUID) {
        if userDefaults.bool(forKey: dashboardConfiguredKey), dashboardVisibleHabitIds.isEmpty {
            return
        }
        guard !dashboardVisibleHabitIds.isEmpty else { return }
        guard !dashboardVisibleHabitIds.contains(id) else { return }
        setDashboardVisibleHabitIds(dashboardVisibleHabitIds + [id])
    }

    func moveHabit(fromOffsets: IndexSet, toOffset: Int) {
        var copy = orderedHabitIds
        let items = fromOffsets.sorted().reversed().map { copy.remove(at: $0) }.reversed()
        let insertAt = min(toOffset, copy.count)
        copy.insert(contentsOf: items, at: insertAt)
        setOrderedHabitIds(copy)
    }

    // MARK: - Private Methods

    private func save(_ ids: [UUID], forKey key: String) {
        userDefaults.set(ids.map(\.uuidString), forKey: key)
    }

    private static func loadUUIDs(forKey key: String, from defaults: UserDefaults) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }
}
