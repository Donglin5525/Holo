//
//  HoloServerFeatureFlags.swift
//  Holo
//
//  服务端可控的客户端行为开关（P2 路由急停）。
//  值由 HoloSubscriptionService.refreshStatus 从订阅状态响应写入（admin 后台改完即生效，
//  客户端下次刷新时应用）；未下发时按本地默认值走。急停语义：下发 false → 对应能力关闭。
//

import Foundation
import Combine

/// 服务端开关落盘后的广播：开关值写在 UserDefaults 里不会触发 SwiftUI 重绘，
/// 入口显隐类 UI（如目标页「一起想清楚」菜单）监听它即时刷新，避免冷启动拉到开关后菜单仍按旧值渲染
extension Notification.Name {
    static let holoServerFlagsDidUpdate = Notification.Name("holo_server_flags_did_update")
}

nonisolated enum HoloServerFeatureFlags {
    private static let prefix = "holo_server_flag_"

    /// 服务端是否已下发该开关的值
    static func hasValue(_ flag: String) -> Bool {
        UserDefaults.standard.object(forKey: prefix + flag) != nil
    }

    /// 读取开关值；未下发时返回 localDefault
    static func value(_ flag: String, localDefault: Bool) -> Bool {
        UserDefaults.standard.object(forKey: prefix + flag) as? Bool ?? localDefault
    }

    /// 由订阅状态响应写入（nil 字段=服务端未下发该开关，清掉本地覆盖回默认）
    static func apply(_ flags: [String: Bool]?) {
        let defaults = UserDefaults.standard
        guard let flags else { return }
        for (flag, value) in flags {
            defaults.set(value, forKey: prefix + flag)
        }
        NotificationCenter.default.post(name: .holoServerFlagsDidUpdate, object: nil)
    }

    // MARK: - 已知开关

    /// 意图识别 query_analysis / flexible_data_query 走本地 Agent 的服务端总闸。
    /// false = 急停（回到纯 chat 链路），与本地 agentRuntimeEnabled 是 AND 关系。
    static var agentDeepAnalysis: Bool {
        value("agentDeepAnalysis", localDefault: true)
    }

    /// 目标共创（一起想清楚）灰度开关：false = 走旧 AI 规划与手动创建。
    /// 产品决策（2026-09-19 东林拍板）：开闸后该功能不占对话额度、免费用户全量开放，
    /// 开关仅作线上急停用，不做任何付费档位门槛。
    static var goalWorkshopV1: Bool {
        value("goalWorkshopV1", localDefault: false)
    }
}
