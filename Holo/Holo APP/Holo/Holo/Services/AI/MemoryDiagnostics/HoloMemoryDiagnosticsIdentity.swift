//
//  HoloMemoryDiagnosticsIdentity.swift
//  Holo
//
//  记忆链路可诊断基线（体检 G0）：当前开关/授权/闸门与管线版本的静态身份快照。
//  只含配置元数据，不含任何用户数据、摘要或 Prompt 原文。
//

import Foundation

/// 记忆两条萃取链路的版本登记（体检 G0 收拢：原先散落在调用点的字面量）。
/// 变更版本即意味着模型输出契约变化，必须与双端 Prompt 契约同步推进。
nonisolated enum HoloMemoryPipelineVersions {
    /// 领域萃取/跨域融合链路（HoloMemoryObservationScheduler 任务登记）。
    static let domainExtractorVersion = 1
    static let domainPromptVersion = 2
    /// 个人情境萃取链路（applyObservationBatch 落库登记）。
    /// v2（2026-10-09 存量重建迁移）：域判定根治+提示词人话纪律后全量重萃取，
    /// 记录戳随之提升；重建迁移以 promptVersion ≥ 2 识别新管线记录防竞态误伤。
    static let personalExtractorVersion = 2
    static let personalPromptVersion = 2
}

/// 记忆链路当前生效配置的一次性快照：供日志与「AI 记忆实验室」定位
/// 「功能在不在跑」类问题——先看身份（哪个闸关了、哪个版本在跑），再看漏斗。
nonisolated struct HoloMemoryDiagnosticsIdentity: Equatable, Sendable {
    var rolloutStage: String
    var isInternalAccount: Bool
    var isLimitedRolloutBucket: Bool
    var automaticMemoryEnabled: Bool
    var memoryAssistedAnsweringEnabled: Bool
    var aiDataProcessingConsentGranted: Bool
    /// 个人情境三条闸的当轮结论（E02：均要求 isInternalAccount）。
    var personalContextAllowsExtraction: Bool
    var personalContextAllowsRetrieval: Bool
    var personalContextAllowsPlanningInjection: Bool
    var domainExtractorVersion: Int
    var domainPromptVersion: Int
    var personalExtractorVersion: Int
    var personalPromptVersion: Int
    var appVersion: String
    var buildNumber: String
    var recordedAt: Date

    @MainActor
    static func current(now: Date = Date()) -> HoloMemoryDiagnosticsIdentity {
        let productPolicy = HoloMemoryRolloutProductPolicy.current
        let automaticMemoryEnabled = HoloMemorySettings.shared.automaticMemoryEnabled
        let answeringEnabled = HoloMemorySettings.shared.memoryAssistedAnsweringEnabled
        let consentGranted = HoloAIDataProcessingConsent.shared.isGranted
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: productPolicy.isInternalAccount,
            automaticMemoryEnabled: automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: answeringEnabled,
            aiDataProcessingConsentGranted: consentGranted
        )
        let info = Bundle.main.infoDictionary
        return HoloMemoryDiagnosticsIdentity(
            rolloutStage: productPolicy.rolloutStage.rawValue,
            isInternalAccount: productPolicy.isInternalAccount,
            isLimitedRolloutBucket: productPolicy.isLimitedRolloutBucket,
            automaticMemoryEnabled: automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: answeringEnabled,
            aiDataProcessingConsentGranted: consentGranted,
            personalContextAllowsExtraction: controls.allowsExtraction,
            personalContextAllowsRetrieval: controls.allowsRetrieval,
            personalContextAllowsPlanningInjection: controls.allowsPlanningInjection,
            domainExtractorVersion: HoloMemoryPipelineVersions.domainExtractorVersion,
            domainPromptVersion: HoloMemoryPipelineVersions.domainPromptVersion,
            personalExtractorVersion: HoloMemoryPipelineVersions.personalExtractorVersion,
            personalPromptVersion: HoloMemoryPipelineVersions.personalPromptVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            recordedAt: now
        )
    }

    /// 单行公开元数据日志（不含用户数据，可直接进 log stream 诊断）。
    var logLine: String {
        "MEMORY-IDENTITY rollout=\(rolloutStage) internal=\(isInternalAccount) bucket=\(isLimitedRolloutBucket) "
            + "autoMemory=\(automaticMemoryEnabled) assistedAnswer=\(memoryAssistedAnsweringEnabled) "
            + "consent=\(aiDataProcessingConsentGranted) "
            + "gates(extract/retrieve/inject)=\(personalContextAllowsExtraction)/\(personalContextAllowsRetrieval)/\(personalContextAllowsPlanningInjection) "
            + "pipeline(domain \(domainExtractorVersion)/\(domainPromptVersion), personal \(personalExtractorVersion)/\(personalPromptVersion)) "
            + "app=\(appVersion)(\(buildNumber))"
    }
}
