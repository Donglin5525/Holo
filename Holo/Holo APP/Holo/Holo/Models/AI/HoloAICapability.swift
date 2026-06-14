//
//  HoloAICapability.swift
//  Holo
//
//  HoloAI 能力启动台入口模型
//

import Foundation
import Combine

enum HoloAICapabilityID: String, Codable, CaseIterable, Equatable {
    case onboarding
    case todayState
    case recentAnalysis
    case longTermPatterns
    case goalPlanning
}

struct HoloAICapability: Identifiable, Equatable {
    let id: HoloAICapabilityID
    let title: String
    let systemImage: String
    let isEmphasized: Bool
    let isEnabled: Bool
}

// MARK: - Memory Settings (User-Controlled)

final class HoloMemorySettings: ObservableObject {
    static let shared = HoloMemorySettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let longTermMemoryEnabled = "holo_memory_longTermEnabled"
        static let memoryInsightExtractionEnabled = "holo_memory_insightExtractionEnabled"
        static let memorySummaryInjectionEnabled = "holo_memory_summaryInjectionEnabled"
        static let episodicMemoryObservationEnabled = "holo_memory_episodicObservationEnabled"
        static let semanticMemoryTypesEnabled = "holo_memory_semanticTypesEnabled"
        static let semanticMemoryPromptEnabled = "holo_memory_semanticPromptEnabled"
        static let semanticMemoryRecallEnabled = "holo_memory_semanticRecallEnabled"

        // Profile Snapshot Feature Flags
        static let profileSnapshotEnabled = "holo_profile_snapshotEnabled"
        static let profileAnalysisInjectionEnabled = "holo_profile_analysisInjectionEnabled"

        // HoloAI Agent Feature Flags (V3.1，默认全 false)
        static let agentRuntimeEnabled = "holo_agent_runtimeEnabled"
        static let agentDebugModeEnabled = "holo_agent_debugModeEnabled"
        static let agentMemoryGalleryEnabled = "holo_agent_memoryGalleryEnabled"
        static let agentObserverTier2Enabled = "holo_agent_observerTier2Enabled"
    }

    @Published var longTermMemoryEnabled: Bool {
        didSet { defaults.set(longTermMemoryEnabled, forKey: Keys.longTermMemoryEnabled) }
    }

    @available(*, deprecated, message: "未使用，请使用 episodicMemoryObservationEnabled")
    @Published var memoryInsightExtractionEnabled: Bool {
        didSet { defaults.set(memoryInsightExtractionEnabled, forKey: Keys.memoryInsightExtractionEnabled) }
    }

    @Published var memorySummaryInjectionEnabled: Bool {
        didSet { defaults.set(memorySummaryInjectionEnabled, forKey: Keys.memorySummaryInjectionEnabled) }
    }

    @Published var episodicMemoryObservationEnabled: Bool {
        didSet { defaults.set(episodicMemoryObservationEnabled, forKey: Keys.episodicMemoryObservationEnabled) }
    }

    /// 语义类型模型和晋升策略（默认 false）
    @Published var semanticMemoryTypesEnabled: Bool {
        didSet { defaults.set(semanticMemoryTypesEnabled, forKey: Keys.semanticMemoryTypesEnabled) }
    }

    /// 洞察 prompt 输出 memoryCandidate 子结构（默认 false）
    @Published var semanticMemoryPromptEnabled: Bool {
        didSet { defaults.set(semanticMemoryPromptEnabled, forKey: Keys.semanticMemoryPromptEnabled) }
    }

    /// 新格式召回（useScopes + prohibitedInferences）（默认 false）
    @Published var semanticMemoryRecallEnabled: Bool {
        didSet { defaults.set(semanticMemoryRecallEnabled, forKey: Keys.semanticMemoryRecallEnabled) }
    }

    // MARK: - Profile Snapshot Feature Flags

    /// 控制是否使用结构化 snapshot + renderer（关闭回退到 raw markdown 注入）
    @Published var profileSnapshotEnabled: Bool {
        didSet { defaults.set(profileSnapshotEnabled, forKey: Keys.profileSnapshotEnabled) }
    }

    /// 控制分析查询 / FlexibleQuery 路径是否注入 profile（关闭保持现有分析行为）
    @Published var profileAnalysisInjectionEnabled: Bool {
        didSet { defaults.set(profileAnalysisInjectionEnabled, forKey: Keys.profileAnalysisInjectionEnabled) }
    }

    // MARK: - HoloAI Agent Feature Flags (V3.1，默认全 false)

    /// 本地 Agent Runtime 是否启用（深度分析主入口灰度开关）
    @Published var agentRuntimeEnabled: Bool {
        didSet { defaults.set(agentRuntimeEnabled, forKey: Keys.agentRuntimeEnabled) }
    }

    /// Agent Debug 模式（内部调试入口）
    @Published var agentDebugModeEnabled: Bool {
        didSet { defaults.set(agentDebugModeEnabled, forKey: Keys.agentDebugModeEnabled) }
    }

    /// 记忆长廊读取 Agent Result 灰度开关
    @Published var agentMemoryGalleryEnabled: Bool {
        didSet { defaults.set(agentMemoryGalleryEnabled, forKey: Keys.agentMemoryGalleryEnabled) }
    }

    /// Observer Tier 2 自动触发 Agent 灰度开关
    @Published var agentObserverTier2Enabled: Bool {
        didSet { defaults.set(agentObserverTier2Enabled, forKey: Keys.agentObserverTier2Enabled) }
    }

    private init() {
        self.longTermMemoryEnabled = defaults.object(forKey: Keys.longTermMemoryEnabled) as? Bool ?? false
        self.memoryInsightExtractionEnabled = defaults.object(forKey: Keys.memoryInsightExtractionEnabled) as? Bool ?? false
        self.memorySummaryInjectionEnabled = defaults.object(forKey: Keys.memorySummaryInjectionEnabled) as? Bool ?? true
        self.episodicMemoryObservationEnabled = defaults.object(forKey: Keys.episodicMemoryObservationEnabled) as? Bool ?? false
        self.semanticMemoryTypesEnabled = defaults.object(forKey: Keys.semanticMemoryTypesEnabled) as? Bool ?? false
        self.semanticMemoryPromptEnabled = defaults.object(forKey: Keys.semanticMemoryPromptEnabled) as? Bool ?? false
        self.semanticMemoryRecallEnabled = defaults.object(forKey: Keys.semanticMemoryRecallEnabled) as? Bool ?? false

        // Profile Snapshot 默认启用（核心功能升级，非实验性）
        self.profileSnapshotEnabled = defaults.object(forKey: Keys.profileSnapshotEnabled) as? Bool ?? true
        self.profileAnalysisInjectionEnabled = defaults.object(forKey: Keys.profileAnalysisInjectionEnabled) as? Bool ?? true

        // HoloAI Agent 默认全 false（灰度阶段不接入主入口）
        self.agentRuntimeEnabled = defaults.object(forKey: Keys.agentRuntimeEnabled) as? Bool ?? false
        self.agentDebugModeEnabled = defaults.object(forKey: Keys.agentDebugModeEnabled) as? Bool ?? false
        self.agentMemoryGalleryEnabled = defaults.object(forKey: Keys.agentMemoryGalleryEnabled) as? Bool ?? false
        self.agentObserverTier2Enabled = defaults.object(forKey: Keys.agentObserverTier2Enabled) as? Bool ?? false
    }
}

// MARK: - Feature Flags (Read from Settings)

enum HoloAIFeatureFlags {
    static var capabilityLaunchpadEnabled: Bool { true }
    static var memorySummaryInjectionEnabled: Bool { HoloMemorySettings.shared.memorySummaryInjectionEnabled }
    static var longTermMemoryWriteEnabled: Bool { HoloMemorySettings.shared.longTermMemoryEnabled }
    static var memoryInsightCandidateExtractionEnabled: Bool { HoloMemorySettings.shared.longTermMemoryEnabled }
    static var episodicMemoryObservationEnabled: Bool { HoloMemorySettings.shared.episodicMemoryObservationEnabled }

    // MARK: - 语义记忆类型化 Feature Flags（Phase 6，默认全 false）

    /// 控制语义类型模型和晋升策略
    static var semanticMemoryTypesEnabled: Bool {
        HoloMemorySettings.shared.semanticMemoryTypesEnabled
    }

    /// 控制洞察 prompt 输出 memoryCandidate 子结构
    static var semanticMemoryPromptEnabled: Bool {
        HoloMemorySettings.shared.semanticMemoryPromptEnabled
    }

    /// 控制新格式召回（useScopes + prohibitedInferences）
    static var semanticMemoryRecallEnabled: Bool {
        HoloMemorySettings.shared.semanticMemoryRecallEnabled
    }

    // MARK: - Profile Snapshot Feature Flags

    /// 控制是否使用结构化 snapshot + renderer；关闭回退到 raw markdown 注入
    static var profileSnapshotEnabled: Bool {
        HoloMemorySettings.shared.profileSnapshotEnabled
    }

    /// 控制分析查询 / FlexibleQuery 路径是否注入 profile
    static var profileAnalysisInjectionEnabled: Bool {
        HoloMemorySettings.shared.profileAnalysisInjectionEnabled
    }

    // MARK: - HoloAI Agent Feature Flags (V3.1，默认全 false)

    /// 本地 Agent Runtime 是否启用（深度分析主入口灰度开关）
    static var agentRuntimeEnabled: Bool {
        HoloMemorySettings.shared.agentRuntimeEnabled
    }

    /// Agent Debug 模式
    static var agentDebugModeEnabled: Bool {
        HoloMemorySettings.shared.agentDebugModeEnabled
    }

    /// 记忆长廊读取 Agent Result
    static var agentMemoryGalleryEnabled: Bool {
        HoloMemorySettings.shared.agentMemoryGalleryEnabled
    }

    /// Observer Tier 2 自动触发
    static var agentObserverTier2Enabled: Bool {
        HoloMemorySettings.shared.agentObserverTier2Enabled
    }
}
