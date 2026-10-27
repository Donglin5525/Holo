//
//  DiscoverySettingsSupport.swift
//  Holo
//
//  「一个发现」设置侧共享件：settingsDetailState 九态文案映射（01 §1 设置子页列）、
//  来源域展示元数据（想法/任务/习惯）。供 DiscoverySettingsView、HoloAIUserSettingsView、
//  DiscoveryFirstEnableSheet 共用。
//

import SwiftUI

/// 九态 → 设置页文案（主行 + 说明行）的唯一定义处
enum DiscoverySettingsCopy {

    /// 设置子页主状态文案（01 §1 状态表第 3 列）
    static func statusText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled: return "已关闭，可开启"
        case .preparing: return "正在准备"
        case .waitingForMaterial: return "有足够依据时再呈现"
        case .hasFinding(viewed: false): return "有一个发现"
        case .hasFinding(viewed: true): return "已看，可重读"
        case .stale: return "等待新的线索"
        case .pausedTemporarily: return "暂未更新"
        case .revoked: return "已关闭 / 授权已撤回"
        case .serverUnsupported: return "暂不可用"
        }
    }

    /// 设置子页状态说明行（不催促、不暗示后台已分析）
    static func statusDetailText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled:
            return "由你决定什么时候开启；开启前不会分析你的记录。"
        case .preparing:
            return "需要一些准备时间，不必在这里等待。"
        case .waitingForMaterial:
            return "记录不足或解释不可靠时不呈现，不保证每天更新。"
        case .hasFinding(viewed: false):
            return "已核对记录依据，等你想看时在对话页打开。"
        case .hasFinding(viewed: true):
            return "这条发现仍有效，可随时重读。"
        case .stale:
            return "上一条已过期或来源失效，等待新的线索。"
        case .pausedTemporarily:
            return "暂未更新，不需要你做任何操作。"
        case .revoked:
            return "数据处理授权已撤回；恢复总授权不会自动重新开启。"
        case .serverUnsupported:
            return "发现服务暂未开放，尚未开启；服务恢复后可重新尝试。"
        }
    }

    /// 统一设置页主条目行的副标题（比子页更简短的口径）
    static func summaryText(for state: DiscoverySettingsDetailState) -> String {
        switch state {
        case .disabled, .revoked: return "已关闭"
        case .preparing: return "正在准备"
        case .waitingForMaterial, .stale: return "等待新的线索"
        case .hasFinding: return "有一个发现"
        case .pausedTemporarily: return "暂未更新"
        case .serverUnsupported: return "暂不可用"
        }
    }

    /// 该状态下功能开关是否处于“开”（serverUnsupported 时开关不可完成开启，按关显示）
    static func isEnabledState(_ state: DiscoverySettingsDetailState) -> Bool {
        switch state {
        case .disabled, .revoked, .serverUnsupported: return false
        default: return true
        }
    }

    /// 开关行是否可交互（后端不支持时禁止开启）
    static func isToggleDisabled(_ state: DiscoverySettingsDetailState) -> Bool {
        state == .serverUnsupported
    }
}

/// 来源域（想法/任务/习惯）的展示元数据：首开多选与设置页「允许来源」共用
struct DiscoveryDomainMeta: Identifiable {
    let domain: DiscoverySourceDomain
    let title: String
    let subtitle: String
    let icon: String

    var id: String { domain.rawValue }

    static let all: [DiscoveryDomainMeta] = [
        DiscoveryDomainMeta(domain: .thought, title: "想法", subtitle: "你记下的想法与笔记正文", icon: "lightbulb"),
        DiscoveryDomainMeta(domain: .task, title: "任务", subtitle: "待办的创建与完成情况", icon: "checklist"),
        DiscoveryDomainMeta(domain: .habit, title: "习惯", subtitle: "习惯打卡记录", icon: "flame")
    ]
}
