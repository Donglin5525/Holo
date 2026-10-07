//
//  HabitMilestoneStore.swift
//  Holo
//
//  里程碑本机展示账本（2026-10 重构，方案 §9.4）：
//  - 仅好习惯；阈值 daily 7/30/100 天、weekly 4/12/52 周、monthly 3/6/12 月
//  - 去重键 = habit UUID + 指标种类 + 周期单位 + 阈值；本机 UserDefaults，不入云
//  - 已展示的里程碑不因撤销/重做、回页、云同步或重启反复播放
//  - 升级/首次开启时历史达标徽章静态展示，不集中补播庆祝
//

import Foundation

/// 非订阅式账本：不继承 ObservableObject——里程碑动效由“确认保存成功”事件驱动，
/// 页面手动查询/标记即可（订阅式刷新在本测试宿主有 malloc 析构崩溃，实测在档）。
@MainActor
final class HabitMilestoneStore {

    /// 里程碑定义（阈值按真实单位，不把月/周折算成天）
    struct Definition: Equatable {
        let threshold: Int
        let unit: HabitStreakUnit
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var displayedKeys: Set<String>

    init(defaults: UserDefaults = .standard, storageKey: String = "habit.milestone.displayed.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.displayedKeys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// 各频率的里程碑阈值表（仅好习惯）
    static func definitions(for frequency: HabitFrequency) -> [Definition] {
        switch frequency {
        case .daily:
            return [7, 30, 100].map { Definition(threshold: $0, unit: .day) }
        case .weekly:
            return [4, 12, 52].map { Definition(threshold: $0, unit: .week) }
        case .monthly:
            return [3, 6, 12].map { Definition(threshold: $0, unit: .month) }
        }
    }

    /// 去重键（habit UUID + 指标种类 + 周期单位 + 阈值）
    static func key(habitId: UUID, kindName: String, unit: HabitStreakUnit, threshold: Int) -> String {
        "\(habitId.uuidString)|\(kindName)|\(unit.rawValue)|\(threshold)"
    }

    /// 当前连续积累已达成的全部里程碑（静态展示资格；与是否播过无关）
    func achievedMilestones(habitId: UUID, streak: HabitStreakLabel, frequency: HabitFrequency) -> [HabitMilestone] {
        Self.definitions(for: frequency).compactMap { definition in
            guard streak.unitName == definition.unit.displayName,
                  streak.value >= definition.threshold else { return nil }
            return HabitMilestone(
                key: Self.key(habitId: habitId, kindName: streak.kindName,
                              unit: definition.unit, threshold: definition.threshold),
                habitId: habitId,
                threshold: definition.threshold,
                unitName: definition.unit.displayName,
                kindName: streak.kindName
            )
        }
    }

    /// 是否已播放过该里程碑
    func isDisplayed(_ milestone: HabitMilestone) -> Bool {
        displayedKeys.contains(milestone.key)
    }

    /// 标记已播放（真实跨阈值后的首次展示调用一次）
    func markDisplayed(_ milestone: HabitMilestone) {
        displayedKeys.insert(milestone.key)
        defaults.set(Array(displayedKeys), forKey: storageKey)
    }
}
