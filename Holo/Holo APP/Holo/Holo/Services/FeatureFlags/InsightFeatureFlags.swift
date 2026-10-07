//
//  InsightFeatureFlags.swift
//  Holo
//
//  Sense Layer 洞察闭环功能的 Feature Flags
//  基于 UserDefaults Bool，Debug/TestFlight 默认开启，Release 可关闭
//

import Foundation

struct InsightFeatureFlags {
    private static let defaults = UserDefaults.standard

    // MARK: - Flag Keys

    private enum FlagKey: String {
        case feedbackEnabled = "insight.feedback.enabled"
        case preferenceLearningEnabled = "insight.preferenceLearning.enabled"
        case rerankEnabled = "insight.rerank.enabled"
        case dailySenseEnabled = "insight.dailySense.enabled"
        case healthContextEnabled = "insight.healthContext.enabled"
        case actionCandidateEnabled = "insight.actionCandidate.enabled"
    }

    // MARK: - Defaults

    /// Debug/TestFlight 默认开启，Release 默认关闭
    private static var defaultEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// 健康素材默认开启（2026-09-24 东林拍板）：隐私同意 v2 文案本就承诺
    /// 「周期回放素材含健康与活动摘要」，Release 关闭导致文案与行为不符；
    /// 健康摘要走快照密文 + 完成即焚通道，与深度分析侧健康域同一口径。
    private static var healthContextDefaultEnabled: Bool { true }

    // MARK: - Flags

    static var feedbackEnabled: Bool {
        get { defaults.object(forKey: FlagKey.feedbackEnabled.rawValue) as? Bool ?? defaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.feedbackEnabled.rawValue) }
    }

    static var preferenceLearningEnabled: Bool {
        get { defaults.object(forKey: FlagKey.preferenceLearningEnabled.rawValue) as? Bool ?? defaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.preferenceLearningEnabled.rawValue) }
    }

    static var rerankEnabled: Bool {
        get { defaults.object(forKey: FlagKey.rerankEnabled.rawValue) as? Bool ?? defaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.rerankEnabled.rawValue) }
    }

    static var dailySenseEnabled: Bool {
        get { defaults.object(forKey: FlagKey.dailySenseEnabled.rawValue) as? Bool ?? defaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.dailySenseEnabled.rawValue) }
    }

    static var healthContextEnabled: Bool {
        get { defaults.object(forKey: FlagKey.healthContextEnabled.rawValue) as? Bool ?? healthContextDefaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.healthContextEnabled.rawValue) }
    }

    static var actionCandidateEnabled: Bool {
        get { defaults.object(forKey: FlagKey.actionCandidateEnabled.rawValue) as? Bool ?? defaultEnabled }
        set { defaults.set(newValue, forKey: FlagKey.actionCandidateEnabled.rawValue) }
    }

    // MARK: - Reset

    /// 重置所有 insight feature flags 为默认值
    static func resetAll() {
        for key in [
            FlagKey.feedbackEnabled,
            .preferenceLearningEnabled,
            .rerankEnabled,
            .dailySenseEnabled,
            .healthContextEnabled,
            .actionCandidateEnabled
        ] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
