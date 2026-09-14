//
//  HoloTodayRolloutPolicy.swift
//  Holo
//
//  「今天」新版灰度开关（今日看板 Matter 化方案 §15.1）
//
//  独立于 HoloMatterRolloutPolicy：「今天」即使没有 Matter 也必须服务普通日程、
//  任务和习惯，两者生命周期不能强耦合。
//  - 开：新首页入口摘要 + 新 Today + 首页独立 Matter 卡隐藏；
//  - 关：旧 DailyKanbanEntryButton + 旧 DailyKanbanView + 旧 MatterFocusCard 全部恢复；
//  - 首版单一开关，不为小区块加组合 flag（避免不可测状态空间）。
//

import Foundation

nonisolated enum HoloTodayRolloutPolicy {

    nonisolated enum Flag: String {
        case todayCommandCenterEnabled
    }

    private static let defaults = UserDefaults.standard

    /// 默认开启（与 Matter 基础三开关同策略：关闭即完整恢复旧版，回滚不删数据）。
    /// 用户显式设置过则尊重设置。
    static var isEnabled: Bool {
        if let explicit = defaults.object(forKey: Flag.todayCommandCenterEnabled.rawValue) as? Bool {
            return explicit
        }
        return true
    }

    /// 调试/灰度切换（生产默认开启；关闭入口在设置-诊断页）。
    static func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Flag.todayCommandCenterEnabled.rawValue)
    }
}
