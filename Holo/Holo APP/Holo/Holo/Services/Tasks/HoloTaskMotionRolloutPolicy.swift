//
//  HoloTaskMotionRolloutPolicy.swift
//  Holo
//
//  B「活页归档」视觉灰度开关（动效融合定稿 §6 G2）
//
//  只控制任务完成表达的外观（纸页行 / 事簿记录行 / 完成回执 / 撤回 toast /
//  列表纸页头），不改变任务或 Matter 存储格式——关闭即完整恢复原布局，
//  回退无需数据迁移。完成业务契约（撤回窗口、落库时机）由
//  HoloTaskCompletionCoordinator 统一持有，与本开关无关。
//

import Foundation

nonisolated enum HoloTaskMotionRolloutPolicy {

    nonisolated enum Flag: String {
        case taskPaperMotionEnabled
    }

    private static let defaults = UserDefaults.standard

    /// 默认开启（与 todayCommandCenterEnabled 同策略：显式设置过则尊重设置）。
    static var isEnabled: Bool {
        if let explicit = defaults.object(forKey: Flag.taskPaperMotionEnabled.rawValue) as? Bool {
            return explicit
        }
        return true
    }

    /// 调试/灰度切换（关闭入口走 UserDefaults / 诊断通道）。
    static func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Flag.taskPaperMotionEnabled.rawValue)
    }
}
