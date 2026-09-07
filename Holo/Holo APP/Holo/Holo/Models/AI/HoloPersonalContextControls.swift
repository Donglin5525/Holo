//
//  HoloPersonalContextControls.swift
//  Holo
//
//  通用个人情境理解与规划（HoloAI 通用情境）的内部控制闸。
//
//  四个独立 kill 闸：extraction（后台萃取与历史补建）、retrieval（混合检索与目录）、
//  planningInjection（把情境注入聊天/目标/Agent 的回答）、rawFallback（原文兜底补查）。
//  默认仅内部账号启用；总闸始终与用户记忆开关、AI 数据处理同意相与（见 gates 规则）。
//  关系约束：rawFallback 依附 retrieval（检索都不允许时绝不直接翻原文）。
//  本文件不依赖 App 运行时类型，可被 standalone 测试直接编译。
//

import Foundation

/// 通用情境能力的控制快照：所有输入显式注入，闸门规则集中在此，便于确定性测试。
struct HoloPersonalContextControlSnapshot: Codable, Equatable, Sendable {
    /// 四个 kill 键（true = 允许；默认 true，用 UserDefaults 关闭以应急回退）。
    var extractionKillEnabled: Bool
    var retrievalKillEnabled: Bool
    var planningInjectionKillEnabled: Bool
    var rawFallbackKillEnabled: Bool
    /// 内部账号（灰度门：首版仅内部账号可用）。
    var isInternalAccount: Bool
    /// 用户「自动形成记忆」开关：只管萃取与补建，不管读取。
    var automaticMemoryEnabled: Bool
    /// 用户「记忆辅助回答」开关：管新情境读取、注入与原文兜底。
    var memoryAssistedAnsweringEnabled: Bool
    /// AI 数据处理同意：未同意时任何文本/向量都不得外发，全部闸门关闭。
    var aiDataProcessingConsentGranted: Bool

    /// 背景萃取与历史补建。
    var allowsExtraction: Bool {
        extractionKillEnabled
            && isInternalAccount
            && automaticMemoryEnabled
            && aiDataProcessingConsentGranted
    }

    /// 混合检索（向量/目录/当前状态读取）。检索是数据面闸门，可独立于注入开启做脱敏计数。
    var allowsRetrieval: Bool {
        retrievalKillEnabled
            && isInternalAccount
            && memoryAssistedAnsweringEnabled
            && aiDataProcessingConsentGranted
    }

    /// 把情境注入用户可见的回答/草案。
    var allowsPlanningInjection: Bool {
        planningInjectionKillEnabled
            && isInternalAccount
            && memoryAssistedAnsweringEnabled
            && aiDataProcessingConsentGranted
    }

    /// 原文兜底补查：依附检索闸，检索关闭时原文兜底必然关闭。
    var allowsRawFallback: Bool {
        rawFallbackKillEnabled && allowsRetrieval
    }

    /// retrieval 开、injection 关：只做脱敏计数，不在用户回答中显性使用。
    var isShadowRetrieval: Bool {
        allowsRetrieval && !allowsPlanningInjection
    }
}

enum HoloPersonalContextControls {
    private enum Keys {
        static let extraction = "holo_personal_context_kill_extraction_v1"
        static let retrieval = "holo_personal_context_kill_retrieval_v1"
        static let planningInjection = "holo_personal_context_kill_planning_injection_v1"
        static let rawFallback = "holo_personal_context_kill_raw_fallback_v1"
    }

    /// 从 UserDefaults 读 kill 键，与其余输入组装快照。
    /// 用户开关与同意状态由调用方注入（App 侧接 HoloMemorySettings / HoloAIDataProcessingConsent），
    /// 避免本文件依赖运行时单例，保持 standalone 可测。
    static func resolve(
        defaults: UserDefaults,
        isInternalAccount: Bool,
        automaticMemoryEnabled: Bool,
        memoryAssistedAnsweringEnabled: Bool,
        aiDataProcessingConsentGranted: Bool
    ) -> HoloPersonalContextControlSnapshot {
        HoloPersonalContextControlSnapshot(
            extractionKillEnabled: defaults.object(forKey: Keys.extraction) as? Bool ?? true,
            retrievalKillEnabled: defaults.object(forKey: Keys.retrieval) as? Bool ?? true,
            planningInjectionKillEnabled: defaults.object(forKey: Keys.planningInjection) as? Bool ?? true,
            rawFallbackKillEnabled: defaults.object(forKey: Keys.rawFallback) as? Bool ?? true,
            isInternalAccount: isInternalAccount,
            automaticMemoryEnabled: automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: aiDataProcessingConsentGranted
        )
    }

    /// 测试与预检用的全关快照（空开关回退基线）。
    static func allOff() -> HoloPersonalContextControlSnapshot {
        HoloPersonalContextControlSnapshot(
            extractionKillEnabled: false,
            retrievalKillEnabled: false,
            planningInjectionKillEnabled: false,
            rawFallbackKillEnabled: false,
            isInternalAccount: false,
            automaticMemoryEnabled: false,
            memoryAssistedAnsweringEnabled: false,
            aiDataProcessingConsentGranted: false
        )
    }
}
