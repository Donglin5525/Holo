//
//  HoloMemoryAttentionPolicy.swift
//  Holo
//
//  所有 UI 判断「是否需要用户处理记忆」的唯一入口（低确认成本方案 §11.3）。
//
//  - 禁止在 UI、查询、回执里再用 `record.state == .candidate` 单独判断待确认；
//  - P1 桥接口径：每日批量确认收件箱整体下线（adviceEligible 明确豁免，其余 candidate
//    不再构成用户任务）；P2 起由 decision metadata 的 attentionPolicy 接管细分；
//  - 回滚位：UserDefaults 写 false 恢复旧口径（方案 §18.2：回滚不清库、不回退用户决定）。
//

import Foundation

nonisolated enum HoloMemoryAttentionPolicy {
    /// 每日确认收件箱下线开关的规范 key；HoloAIFeatureFlags 同名属性从这里读取。
    static let dailyConfirmationInboxDisabledKey = "holo_memory_dailyConfirmationInboxDisabled"
    private static let firstNoticeShownKey = "holo_memory_first_notice_shown"

    /// P1 起默认下线（产品决策：记忆是后台能力，不是用户每日任务）；
    /// 显式写 false 才回到旧口径，用于回滚演练。
    static var isDailyConfirmationInboxDisabled: Bool {
        UserDefaults.standard.object(forKey: dailyConfirmationInboxDisabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: dailyConfirmationInboxDisabledKey)
    }

    /// 「想和你确认的」队列成员的唯一判定：可见、处于 candidate 生命周期、
    /// 且当前产品口径仍把 candidate 当作用户任务。
    static func requiresDailyConfirmation(_ record: HoloMemoryRecord) -> Bool {
        guard HoloMemoryUserVisibility.isVisible(record),
              record.state == .candidate else {
            return false
        }
        guard !isDailyConfirmationInboxDisabled else {
            // P1：不再制造每日确认任务。adviceEligible/observeOnly/candidate
            // 的用途区分由 P2 五路决策接管；高影响不确定内容在 P4 前保持不使用。
            return false
        }
        return true
    }

    /// 首次成功形成有效记忆时的一次性说明文案（方案 §8.2：替代每日胶囊，
    /// 后续常规自动记忆只在记忆管理内被动可见）。
    static var firstNoticeText: String {
        String(localized: "Holo 会根据你的记录逐渐了解你，你可以随时查看或纠正")
    }

    /// 一次性首启说明是否已展示过。
    static var hasShownFirstNotice: Bool {
        UserDefaults.standard.bool(forKey: firstNoticeShownKey)
    }

    static func markFirstNoticeShown() {
        UserDefaults.standard.set(true, forKey: firstNoticeShownKey)
    }
}
