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

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let visibleKey = "habit.stats.visible.ids"
    private let orderKey = "habit.stats.order.ids"

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.visibleHabitIds = Self.loadUUIDs(forKey: visibleKey, from: userDefaults)
        self.orderedHabitIds = Self.loadUUIDs(forKey: orderKey, from: userDefaults)
    }

    // MARK: - Public Methods

    func setVisibleHabitIds(_ ids: [UUID]) {
        visibleHabitIds = ids
        save(ids, forKey: visibleKey)
    }

    func setOrderedHabitIds(_ ids: [UUID]) {
        orderedHabitIds = ids
        save(ids, forKey: orderKey)
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
