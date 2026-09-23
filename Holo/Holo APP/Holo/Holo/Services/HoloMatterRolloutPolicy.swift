//
//  HoloMatterRolloutPolicy.swift
//  Holo
//
//  Matter「进行中的事」灰度开关（方案 §22.1）
//
//  五个分层开关，依赖只能由左到右开启：
//  storage → activation → scopedChat → inferredAssociation → intervention
//
//  首版默认全关；Debug 构建与内部账号可通过 UserDefaults 打开。
//  关闭高层功能不得阻止用户查看或导出已存在 Matter（只读保留）。
//

import Foundation

nonisolated enum HoloMatterRolloutPolicy {

    nonisolated enum Flag: String, CaseIterable {
        case matterStorageEnabled
        case matterActivationEnabled
        case matterScopedChatEnabled
        case matterInferredAssociationEnabled
        case matterInterventionEnabled
        /// V2 统一启动（2026-09-21 战略收敛）：新规划卡单 CTA + 原子 launchPlan。
        /// 依赖 storage 而非 activation——关闭时回到旧卡片交互，已有 Matter 不受影响。
        case matterUnifiedLaunchV2Enabled

        /// 左侧依赖（层级序）。
        var prerequisites: [Flag] {
            switch self {
            case .matterStorageEnabled: return []
            case .matterActivationEnabled: return [.matterStorageEnabled]
            case .matterScopedChatEnabled: return [.matterActivationEnabled]
            case .matterInferredAssociationEnabled: return [.matterScopedChatEnabled]
            case .matterInterventionEnabled: return [.matterInferredAssociationEnabled]
            case .matterUnifiedLaunchV2Enabled: return [.matterStorageEnabled]
            }
        }
    }

    private static let defaults = UserDefaults.standard

    /// 默认开启的层级（2026-09-13 东林拍板：安全网齐备——AI 动作全可撤销、不自动建业务对象、
    /// 完成必须用户亲手触发，最坏后果只是打扰而非数据破坏，故首版直接全量开放基础三件套）。
    /// inferredAssociation（M4）与 intervention（M5）仍按方案节奏默认关。
    private static let defaultOn: Set<Flag> = [
        .matterStorageEnabled,
        .matterActivationEnabled,
        .matterScopedChatEnabled,
        // V2 首发重构：Debug 构建与内部包先走新链路；回退 = 关此开关回旧卡片交互。
        .matterUnifiedLaunchV2Enabled,
    ]

    /// 指定开关当前是否生效（含依赖链校验：任何前置关闭即视为关闭）。
    /// 用户显式设置过（object 非 nil）则尊重设置；否则取默认值。
    static func isEnabled(_ flag: Flag) -> Bool {
        guard flag.prerequisites.allSatisfy({ isEnabled($0) }) else { return false }
        if let explicit = defaults.object(forKey: flag.rawValue) as? Bool {
            return explicit
        }
        return defaultOn.contains(flag)
    }

    /// 打开开关（仅 Debug 或内部灰度账号可写；依赖自动前置开启）。
    static func setEnabled(_ flag: Flag, enabled: Bool) {
        guard isToggleAllowed else { return }
        if enabled {
            for prerequisite in flag.prerequisites {
                defaults.set(true, forKey: prerequisite.rawValue)
            }
        }
        defaults.set(enabled, forKey: flag.rawValue)
    }

    /// 是否允许切换（首版：Debug 构建可切；线上等远端灰度通道）。
    private static var isToggleAllowed: Bool {
        #if DEBUG
        return true
        #else
        return defaults.bool(forKey: "holoInternalGrayscaleAccount")
        #endif
    }

    // MARK: - 便捷门禁（调用点读这里，不直接读 Flag）

    /// Matter 数据层可用（旧数据只读保留不受开关影响——开关只控制写入入口）。
    static var storageEnabled: Bool { isEnabled(.matterStorageEnabled) }

    /// 是否展示「开始整理」入口与主动建立入口。
    static var activationEnabled: Bool { isEnabled(.matterActivationEnabled) }

    /// 是否允许 Matter-scoped Chat 与对账。
    static var scopedChatEnabled: Bool { isEnabled(.matterScopedChatEnabled) }

    /// 是否展示外部内容候选关联。
    static var inferredAssociationEnabled: Bool { isEnabled(.matterInferredAssociationEnabled) }

    /// 是否允许主动帮助（M5，首版恒 false）。
    static var interventionEnabled: Bool { isEnabled(.matterInterventionEnabled) }

    /// V2 统一启动（新规划卡单 CTA → launchPlan 原子落库）。
    static var unifiedLaunchV2Enabled: Bool { isEnabled(.matterUnifiedLaunchV2Enabled) }
}
