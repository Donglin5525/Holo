//
//  HoloContextEvidenceNavigator.swift
//  Holo
//
//  证据回源导航（2026-09-09 方案 §7.1/§7.2）：来源域+实体 ID → 模块深链。
//  路由由客户端代码解析，绝不把 URL 或路由参数交给模型生成。
//  解析失败（域不可达/ID 非法）返回 false，调用方显示「原记录已删除或当前不可访问」，
//  不跳空页面。
//

import Foundation

nonisolated enum HoloContextEvidenceNavigator {

    /// 按来源域跳转到原实体详情。目标页是否存在由深链响应方决定；
    /// 这里只做「域已知 + ID 合法」的门禁。
    @MainActor
    @discardableResult
    static func navigate(sourceDomain: String, sourceEntityID: String) -> Bool {
        guard let entityUUID = UUID(uuidString: sourceEntityID) else { return false }
        switch sourceDomain.lowercased() {
        case "thought":
            DeepLinkState.shared.navigate(to: .thoughtDetail(thoughtId: entityUUID))
            return true
        case "task", "todo":
            DeepLinkState.shared.navigate(to: .taskDetail(taskId: entityUUID))
            return true
        case "finance", "transaction":
            DeepLinkState.shared.navigate(to: .transactionDetail(transactionId: entityUUID))
            return true
        case "habit":
            DeepLinkState.shared.navigate(to: .habitDetail(habitId: entityUUID))
            return true
        case "goal":
            DeepLinkState.shared.navigate(to: .goalDetail(goalId: entityUUID))
            return true
        case "anniversary":
            DeepLinkState.shared.navigate(to: .anniversaryDetail(anniversaryId: entityUUID))
            return true
        default:
            // conversation/health/memory 等暂无独立详情页的域：诚实不可达
            return false
        }
    }

    /// 来源域的用户可读名称（依据区行首标签）。
    static func displayName(for sourceDomain: String) -> String {
        switch sourceDomain.lowercased() {
        case "thought": return String(localized: "想法")
        case "task", "todo": return String(localized: "任务")
        case "finance", "transaction": return String(localized: "账目")
        case "habit": return String(localized: "习惯")
        case "goal": return String(localized: "目标")
        case "anniversary": return String(localized: "纪念日")
        case "conversation": return String(localized: "对话")
        case "health": return String(localized: "健康")
        case "memory": return String(localized: "记忆")
        default: return sourceDomain
        }
    }
}
