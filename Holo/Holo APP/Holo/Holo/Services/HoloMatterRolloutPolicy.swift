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

        /// 左侧依赖（层级序）。
        var prerequisites: [Flag] {
            switch self {
            case .matterStorageEnabled: return []
            case .matterActivationEnabled: return [.matterStorageEnabled]
            case .matterScopedChatEnabled: return [.matterActivationEnabled]
            case .matterInferredAssociationEnabled: return [.matterScopedChatEnabled]
            case .matterInterventionEnabled: return [.matterInferredAssociationEnabled]
            }
        }
    }

    private static let defaults = UserDefaults.standard

    /// 指定开关当前是否生效（含依赖链校验：任何前置关闭即视为关闭）。
    static func isEnabled(_ flag: Flag) -> Bool {
        guard flag.prerequisites.allSatisfy({ isEnabled($0) }) else { return false }
        return defaults.bool(forKey: flag.rawValue)
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
}
