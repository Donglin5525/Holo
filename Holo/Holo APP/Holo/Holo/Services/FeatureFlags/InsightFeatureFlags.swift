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

    /// Debug/TestFlight 默认全部开启，Release 默认全部关闭
    private static var defaultEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

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
        get { defaults.object(forKey: FlagKey.healthContextEnabled.rawValue) as? Bool ?? defaultEnabled }
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
