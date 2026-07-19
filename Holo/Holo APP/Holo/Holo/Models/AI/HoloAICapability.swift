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

// MARK: - AI Data Processing Consent

final class HoloAIDataProcessingConsent: ObservableObject {
    static let shared = HoloAIDataProcessingConsent()

    private let defaults: UserDefaults
    private let key = "holo_ai_dataProcessingConsentGranted"

    @Published private(set) var isGranted: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isGranted = defaults.bool(forKey: key)
    }

    func grant() {
        defaults.set(true, forKey: key)
        isGranted = true
    }

    func revoke() {
        defaults.set(false, forKey: key)
        isGranted = false
    }

    static var requiredMessage: String {
        "使用 HoloAI、健康洞察或语音转文字前，需要先同意将必要的输入和上下文通过 Holo 后端转发给第三方 AI/语音服务处理。你可以在 HoloAI 数据授权中开启或撤回。"
    }
}

// MARK: - Memory Settings (User-Controlled)

struct HoloMemorySettingsSnapshot: Equatable, Sendable {
    var automaticMemoryEnabled: Bool
    var memoryAssistedAnsweringEnabled: Bool
}

enum HoloMemorySettingsMigration {
    enum LegacyKey {
        static let longTermMemoryEnabled = "holo_memory_longTermEnabled"
        static let memorySummaryInjectionEnabled = "holo_memory_summaryInjectionEnabled"
        static let episodicMemoryObservationEnabled = "holo_memory_episodicObservationEnabled"
    }

    static func resolve(from explicitlyStoredValues: [String: Bool]) -> HoloMemorySettingsSnapshot {
        let automaticMemoryEnabled =
            explicitlyStoredValues[LegacyKey.longTermMemoryEnabled] == true ||
            explicitlyStoredValues[LegacyKey.episodicMemoryObservationEnabled] == true
        let memoryAssistedAnsweringEnabled =
            explicitlyStoredValues[LegacyKey.memorySummaryInjectionEnabled] ?? false

        return HoloMemorySettingsSnapshot(
            automaticMemoryEnabled: automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: memoryAssistedAnsweringEnabled
        )
    }
}

final class HoloMemorySettings: ObservableObject {
    static let shared = HoloMemorySettings()

    private let defaults: UserDefaults
    private var isApplyingRemoteState = false

    private enum Keys {
        static let automaticMemoryEnabled = "holo_memory_automaticMemoryEnabled_v2"
        static let memoryAssistedAnsweringEnabled = "holo_memory_assistedAnsweringEnabled_v2"
        static let userDecisionVersion = "holo_memory_userDecisionVersion_v2"
        static let controlUpdatedAt = "holo_memory_controlUpdatedAt_v2"
        static let longTermMemoryEnabled = "holo_memory_longTermEnabled"
        static let memoryInsightExtractionEnabled = "holo_memory_insightExtractionEnabled"
        static let memorySummaryInjectionEnabled = "holo_memory_summaryInjectionEnabled"
        static let episodicMemoryObservationEnabled = "holo_memory_episodicObservationEnabled"

        // Profile Snapshot Feature Flags
        static let profileSnapshotEnabled = "holo_profile_snapshotEnabled"
        static let profileAnalysisInjectionEnabled = "holo_profile_analysisInjectionEnabled"

        // HoloAI Agent 内部策略键（不作为用户设置项）
        static let agentRuntimeEnabled = "holo_agent_runtimeEnabled"
        static let agentDebugModeEnabled = "holo_agent_debugModeEnabled"
        static let agentMemoryGalleryEnabled = "holo_agent_memoryGalleryEnabled"
        static let agentObserverTier2Enabled = "holo_agent_observerTier2Enabled"
        /// Agent step 级请求幂等（§8.1，产品默认开启；保留键用于测试和紧急回退）
        static let agentStepIdempotencyEnabled = "holo_agent_stepIdempotencyEnabled"
        /// Agent iOS 26 持续处理（§9，产品默认开启；系统版本与授权仍会独立校验）
        static let agentContinuedProcessingEnabled = "holo_agent_continuedProcessingEnabled"
    }

    /// Agent 能力由产品统一管理，不向普通用户暴露技术开关。
    private enum AgentProductPolicy {
        static let runtimeEnabled = true
        static let debugModeEnabled = false
        static let memoryGalleryEnabled = true
        static let observerTier2Enabled = true
        static let stepIdempotencyEnabled = true
        static let continuedProcessingEnabled = true
    }

    @Published var automaticMemoryEnabled: Bool {
        didSet {
            defaults.set(automaticMemoryEnabled, forKey: Keys.automaticMemoryEnabled)
            persistUserControlChangeIfNeeded()
        }
    }

    @Published var memoryAssistedAnsweringEnabled: Bool {
        didSet {
            defaults.set(memoryAssistedAnsweringEnabled, forKey: Keys.memoryAssistedAnsweringEnabled)
            persistUserControlChangeIfNeeded()
        }
    }

    /// 兼容旧调用方；所有旧萃取开关统一映射到“自动形成记忆”。
    var longTermMemoryEnabled: Bool {
        get { automaticMemoryEnabled }
        set { automaticMemoryEnabled = newValue }
    }

    @available(*, deprecated, message: "请使用 automaticMemoryEnabled")
    var memoryInsightExtractionEnabled: Bool {
        get { automaticMemoryEnabled }
        set { automaticMemoryEnabled = newValue }
    }

    var episodicMemoryObservationEnabled: Bool {
        get { automaticMemoryEnabled }
        set { automaticMemoryEnabled = newValue }
    }

    var memorySummaryInjectionEnabled: Bool {
        get { memoryAssistedAnsweringEnabled }
        set { memoryAssistedAnsweringEnabled = newValue }
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

    // MARK: - HoloAI Agent Internal Policies

    /// 本地 Agent Runtime 是否启用（产品默认开启；内部可测试回退）
    @Published var agentRuntimeEnabled: Bool {
        didSet { defaults.set(agentRuntimeEnabled, forKey: Keys.agentRuntimeEnabled) }
    }

    /// Agent Debug 模式（内部调试入口）
    @Published var agentDebugModeEnabled: Bool {
        didSet { defaults.set(agentDebugModeEnabled, forKey: Keys.agentDebugModeEnabled) }
    }

    /// 记忆长廊读取 Agent Result（产品默认开启）
    @Published var agentMemoryGalleryEnabled: Bool {
        didSet { defaults.set(agentMemoryGalleryEnabled, forKey: Keys.agentMemoryGalleryEnabled) }
    }

    /// Observer Tier 2 自动触发 Agent（产品默认开启）
    @Published var agentObserverTier2Enabled: Bool {
        didSet { defaults.set(agentObserverTier2Enabled, forKey: Keys.agentObserverTier2Enabled) }
    }

    /// Agent step 级请求幂等（§8.1，产品默认开启；依赖 agentRuntimeEnabled）
    @Published var agentStepIdempotencyEnabled: Bool {
        didSet { defaults.set(agentStepIdempotencyEnabled, forKey: Keys.agentStepIdempotencyEnabled) }
    }

    /// Agent iOS 26 持续处理（§9，产品默认开启；依赖 step 幂等及系统可用性）
    @Published var agentContinuedProcessingEnabled: Bool {
        didSet { defaults.set(agentContinuedProcessingEnabled, forKey: Keys.agentContinuedProcessingEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let migrated = HoloMemorySettingsMigration.resolve(from: [
            Keys.longTermMemoryEnabled: defaults.object(forKey: Keys.longTermMemoryEnabled) as? Bool,
            Keys.memorySummaryInjectionEnabled: defaults.object(forKey: Keys.memorySummaryInjectionEnabled) as? Bool,
            Keys.episodicMemoryObservationEnabled: defaults.object(forKey: Keys.episodicMemoryObservationEnabled) as? Bool
        ].compactMapValues { $0 })
        self.automaticMemoryEnabled =
            defaults.object(forKey: Keys.automaticMemoryEnabled) as? Bool
            ?? migrated.automaticMemoryEnabled
        self.memoryAssistedAnsweringEnabled =
            defaults.object(forKey: Keys.memoryAssistedAnsweringEnabled) as? Bool
            ?? migrated.memoryAssistedAnsweringEnabled
        // Profile Snapshot 默认启用（核心功能升级，非实验性）
        self.profileSnapshotEnabled = defaults.object(forKey: Keys.profileSnapshotEnabled) as? Bool ?? true
        self.profileAnalysisInjectionEnabled = defaults.object(forKey: Keys.profileAnalysisInjectionEnabled) as? Bool ?? true

        // Agent 核心能力按产品策略统一开启，不沿用历史调试开关，避免升级用户被旧 false 阻断。
        self.agentRuntimeEnabled = AgentProductPolicy.runtimeEnabled
        self.agentDebugModeEnabled = AgentProductPolicy.debugModeEnabled
        self.agentMemoryGalleryEnabled = AgentProductPolicy.memoryGalleryEnabled
        self.agentObserverTier2Enabled = AgentProductPolicy.observerTier2Enabled
        self.agentStepIdempotencyEnabled = AgentProductPolicy.stepIdempotencyEnabled
        self.agentContinuedProcessingEnabled = AgentProductPolicy.continuedProcessingEnabled

        defaults.set(automaticMemoryEnabled, forKey: Keys.automaticMemoryEnabled)
        defaults.set(memoryAssistedAnsweringEnabled, forKey: Keys.memoryAssistedAnsweringEnabled)
        defaults.set(agentRuntimeEnabled, forKey: Keys.agentRuntimeEnabled)
        defaults.set(agentDebugModeEnabled, forKey: Keys.agentDebugModeEnabled)
        defaults.set(agentMemoryGalleryEnabled, forKey: Keys.agentMemoryGalleryEnabled)
        defaults.set(agentObserverTier2Enabled, forKey: Keys.agentObserverTier2Enabled)
        defaults.set(agentStepIdempotencyEnabled, forKey: Keys.agentStepIdempotencyEnabled)
        defaults.set(agentContinuedProcessingEnabled, forKey: Keys.agentContinuedProcessingEnabled)
    }

    private func persistUserControlChangeIfNeeded() {
        guard !isApplyingRemoteState else { return }
        let nextVersion = max(
            defaults.object(forKey: Keys.userDecisionVersion) as? Int64 ?? 0,
            Int64(Date().timeIntervalSince1970 * 1_000)
        ) + 1
        let now = Date()
        defaults.set(nextVersion, forKey: Keys.userDecisionVersion)
        defaults.set(now.timeIntervalSince1970, forKey: Keys.controlUpdatedAt)

        #if !HOLO_MEMORY_STANDALONE
        let state = HoloMemoryControlState(
            automaticMemoryEnabled: automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: memoryAssistedAnsweringEnabled,
            learningBaselineAt: nil,
            userDecisionVersion: nextVersion,
            updatedAt: now
        )
        Task { await HoloMemoryRuntime.shared.saveUserControlState(state) }
        #endif
    }

    #if !HOLO_MEMORY_STANDALONE
    /// 启动时与统一仓库合并控制状态；较新的用户操作胜出，后台结果不能覆盖它。
    func reconcileWithRepository() async {
        guard let remoteState = await HoloMemoryRuntime.shared.loadUserControlState() else { return }
        let localVersion = defaults.object(forKey: Keys.userDecisionVersion) as? Int64 ?? 0

        if remoteState.userDecisionVersion > localVersion {
            isApplyingRemoteState = true
            automaticMemoryEnabled = remoteState.automaticMemoryEnabled
            memoryAssistedAnsweringEnabled = remoteState.memoryAssistedAnsweringEnabled
            defaults.set(remoteState.userDecisionVersion, forKey: Keys.userDecisionVersion)
            defaults.set(remoteState.updatedAt.timeIntervalSince1970, forKey: Keys.controlUpdatedAt)
            isApplyingRemoteState = false
        } else if localVersion > remoteState.userDecisionVersion || (
            localVersion == 0 &&
            (automaticMemoryEnabled != remoteState.automaticMemoryEnabled ||
             memoryAssistedAnsweringEnabled != remoteState.memoryAssistedAnsweringEnabled)
        ) {
            let version = max(localVersion, 1)
            defaults.set(version, forKey: Keys.userDecisionVersion)
            let state = HoloMemoryControlState(
                automaticMemoryEnabled: automaticMemoryEnabled,
                memoryAssistedAnsweringEnabled: memoryAssistedAnsweringEnabled,
                learningBaselineAt: remoteState.learningBaselineAt,
                userDecisionVersion: version,
                updatedAt: Date(
                    timeIntervalSince1970: defaults.double(forKey: Keys.controlUpdatedAt)
                )
            )
            await HoloMemoryRuntime.shared.saveUserControlState(state)
        }
    }
    #endif
}

// MARK: - Memory Operational Controls (Internal Rollout)

enum HoloMemoryRolloutStage: String, Codable, CaseIterable, Sendable {
    case off
    case shadow
    case internalAccounts
    case limited
    case full
}

struct HoloMemoryOperationalControlSnapshot: Equatable, Sendable {
    var rolloutStage: HoloMemoryRolloutStage
    var extractionEnabled: Bool
    var fusionEnabled: Bool
    var answerInjectionEnabled: Bool
    var isInternalAccount: Bool
    var isLimitedRolloutBucket: Bool

    var allowsExtraction: Bool {
        extractionEnabled && rolloutStage != .off
    }

    var allowsFusion: Bool {
        fusionEnabled && rolloutStage != .off
    }

    /// shadow 只生成与评估，不进入任何用户回答。
    var allowsAnswerInjection: Bool {
        guard answerInjectionEnabled else { return false }
        switch rolloutStage {
        case .off, .shadow: return false
        case .internalAccounts: return isInternalAccount
        case .limited: return isInternalAccount || isLimitedRolloutBucket
        case .full: return true
        }
    }

    var isShadowEvaluation: Bool {
        rolloutStage == .shadow && (allowsExtraction || allowsFusion)
    }
}

enum HoloMemoryOperationalControls {
    private enum Keys {
        static let rolloutStage = "holo_memory_rollout_stage_v1"
        static let extractionEnabled = "holo_memory_kill_extraction_v1"
        static let fusionEnabled = "holo_memory_kill_fusion_v1"
        static let answerInjectionEnabled = "holo_memory_kill_answer_injection_v1"
        static let internalAccount = "holo_memory_internal_account_v1"
        static let limitedBucket = "holo_memory_limited_bucket_v1"
    }

    static func current(defaults: UserDefaults = .standard) -> HoloMemoryOperationalControlSnapshot {
        let stage = defaults.string(forKey: Keys.rolloutStage)
            .flatMap(HoloMemoryRolloutStage.init(rawValue:)) ?? .shadow
        return HoloMemoryOperationalControlSnapshot(
            rolloutStage: stage,
            extractionEnabled: defaults.object(forKey: Keys.extractionEnabled) as? Bool ?? true,
            fusionEnabled: defaults.object(forKey: Keys.fusionEnabled) as? Bool ?? true,
            answerInjectionEnabled: defaults.object(forKey: Keys.answerInjectionEnabled) as? Bool ?? true,
            isInternalAccount: defaults.bool(forKey: Keys.internalAccount),
            isLimitedRolloutBucket: defaults.bool(forKey: Keys.limitedBucket)
        )
    }
}

// MARK: - Feature Flags (Read from Settings)

enum HoloAIFeatureFlags {
    static var capabilityLaunchpadEnabled: Bool { true }
    static var aiDataProcessingConsentGranted: Bool { HoloAIDataProcessingConsent.shared.isGranted }
    static var memorySummaryInjectionEnabled: Bool {
        HoloMemorySettings.shared.memoryAssistedAnsweringEnabled &&
        HoloMemoryOperationalControls.current().allowsAnswerInjection
    }
    static var longTermMemoryWriteEnabled: Bool {
        HoloMemorySettings.shared.automaticMemoryEnabled &&
        HoloMemoryOperationalControls.current().allowsExtraction
    }
    static var memoryInsightCandidateExtractionEnabled: Bool { longTermMemoryWriteEnabled }
    static var episodicMemoryObservationEnabled: Bool { longTermMemoryWriteEnabled }
    static var memoryCrossDomainFusionEnabled: Bool {
        HoloMemoryOperationalControls.current().allowsFusion
    }
    static var memoryShadowEvaluationEnabled: Bool {
        HoloMemoryOperationalControls.current().isShadowEvaluation
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

    // MARK: - HoloAI Agent Product Policies

    /// 本地 Agent Runtime 是否启用（产品默认开启）
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

    /// Agent step 级请求幂等（§8.1 产品默认开启；仅在 agentRuntimeEnabled 开启时有意义）
    static var agentStepIdempotencyEnabled: Bool {
        HoloMemorySettings.shared.agentStepIdempotencyEnabled
    }

    /// Agent iOS 26 持续处理（§9 产品默认开启）。
    /// §13.2 依赖顺序：step 幂等失效时本能力强制失效，后一个不能绕过前一个单独生效。
    static var agentContinuedProcessingEnabled: Bool {
        HoloMemorySettings.shared.agentContinuedProcessingEnabled
            && HoloMemorySettings.shared.agentStepIdempotencyEnabled
    }
}
