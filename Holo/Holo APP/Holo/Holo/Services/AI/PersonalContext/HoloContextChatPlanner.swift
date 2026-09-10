//
//  HoloContextChatPlanner.swift
//  Holo
//
//  通用个人情境规划的聊天入口门面（实施方案 §9.1）。
//
//  - ConversationCoordinator 识别 contextual_planning（只读）后由 ChatViewModel 调用。
//  - frame 构建：意图结果的 contextRequest（有则用）；不足时本地轻量构建
//    （成功条件/未知留空，检索方向由 goalSummary 词法派生）——首版不额外发
//    personal_context_request 调用，控制成本口径（§11：复用意图调用不另加 planner）。
//  - 旧后端不支持该意图时不会命中（回退普通聊天），无需降级分支。
//  - 结果是草案（不写任何业务事项）；用户选择保存走 P8 执行适配器。
//

import Foundation
import OSLog

@MainActor
enum HoloContextChatPlanner {
    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "PersonalContextPlanner"
    )

    struct PlanOutcome {
        var draft: HoloContextPlanDraft
        var runID: String
        var semanticCoverage: HoloContextSemanticCoverage
    }

    enum PlannerError: Error, Equatable {
        case gateClosed
        case generationUnavailable
    }

    /// 情境库条数回传盒（recordsProvider 在协调器内部异步执行，诊断用）。
    private final class ContextCountBox: @unchecked Sendable {
        var value = 0
    }

    /// 统一构建规划协调器：语义检索（检索闸开时）+ 想法原文兜底（rawFallback 闸开时）。
    private static func makeCoordinator(
        aiProvider: any AIProvider,
        controls: HoloPersonalContextControlSnapshot,
        repository: any HoloMemoryRepository,
        persistence: HoloPlanningMemoryRunPersistence,
        contextCountOut: ContextCountBox
    ) -> HoloContextPlanningCoordinator {
        let loadContextRecords: @Sendable () async throws -> [HoloMemoryRecord] = {
            // 候选记录来自本机情境库（personalContext 载荷）。
            let records = (try? await repository.query(.all)) ?? []
            let contexts = records.filter { $0.personalContext != nil }
            contextCountOut.value = contexts.count
            logger.error("PLAN-DIAG records=\(records.count) contexts=\(contexts.count)")
            return contexts
        }
        // 语义检索：任何失败由检索服务降级词法（degraded），不阻塞规划。
        let semanticProvider: (any HoloContextSemanticSearchProviding)? = controls.allowsRetrieval
            ? HoloContextSemanticSearchProvider(
                embedding: HoloBackendAIProvider(),
                recordsProvider: loadContextRecords,
                accessGenerationProvider: {
                    let control = (try? await repository.loadControlState())?
                        .userDecisionVersion ?? 0
                    return Int(clamping: control)
                }
            )
            : nil
        // 原文兜底依附检索闸（闸规则见 HoloPersonalContextControls）。
        let rawFallback: (any HoloContextRawFallbackProviding)? = controls.allowsRawFallback
            ? HoloContextThoughtRawFallbackProvider(repository: ThoughtRepository())
            : nil
        return HoloContextPlanningCoordinator(
            generator: HoloContextPlanProviderAdapter(provider: aiProvider),
            retrieval: HoloContextRetrievalService(semanticProvider: semanticProvider),
            persistence: persistence,
            rawFallback: rawFallback,
            recordsProvider: loadContextRecords,
            controlSnapshotProvider: {
                let control = try await repository.loadControlState()
                return HoloContextAccessGuard(
                    userDecisionVersion: control.userDecisionVersion,
                    learningBaselineAt: control.learningBaselineAt,
                    controls: controls
                )
            }
        )
    }

    /// 从聊天请求生成情境方案草案（只读，不写业务事项）。
    /// - Parameters:
    ///   - utterance: 用户本轮原话。
    ///   - parentMessageID: 关联聊天消息（run 跟随追问）。
    ///   - provider: AI Provider（默认后端）。
    static func plan(
        utterance: String,
        parentMessageID: String?,
        provider: (any AIProvider)? = nil,
        onStage: ((HoloPlanningRunState) -> Void)? = nil
    ) async throws -> PlanOutcome {
        let aiProvider = provider ?? HoloBackendAIProvider()

        // 控制闸：注入闸关闭时按旧路走普通聊天（capabilityUnavailable 口径）。
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsPlanningInjection else {
            logger.error("PLAN-DIAG gate closed")
            HoloPersonalContextDiagnostics.recordPlanningGateClosed()
            throw PlannerError.gateClosed
        }

        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            logger.error("PLAN-DIAG repository unavailable")
            throw PlannerError.generationUnavailable
        }

        let frame = HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: utterance,
            referenceTime: Date()
        )

        let persistence = HoloPlanningMemoryRunPersistence()
        let contextCountBox = ContextCountBox()
        let coordinator = Self.makeCoordinator(
            aiProvider: aiProvider,
            controls: controls,
            repository: repository,
            persistence: persistence,
            contextCountOut: contextCountBox
        )

        let outcome = try await coordinator.start(
            frame: frame,
            parentMessageID: parentMessageID,
            onStage: onStage
        )
        logger.error("PLAN-DIAG start ok: run=\(outcome.run.runID) draftItems=\(outcome.draft.items.count) answerLen=\(outcome.draft.answerText.count) entries=\(outcome.retrievalResult.entries.count) selected=\(outcome.retrievalResult.selected.count) coverage=\(outcome.retrievalResult.semanticCoverage.rawValue)")
        HoloPersonalContextDiagnostics.recordPlanning(
            contextCount: contextCountBox.value,
            candidates: outcome.retrievalResult.entries.count,
            selected: outcome.retrievalResult.selected.count,
            coverage: outcome.retrievalResult.semanticCoverage.rawValue,
            rawFallbackUsed: outcome.rawFallbackUsed
        )
        return PlanOutcome(
            draft: outcome.draft,
            runID: outcome.run.runID,
            semanticCoverage: outcome.retrievalResult.semanticCoverage
        )
    }

    /// 保存前权限复查（§10）：背景被忘记/更改/闸关闭后，旧草案不得继续用于保存。
    /// 卡片保存入口调用；与 plan() 同一控制闸口径。
    static func canSave(runID: String, draftRevision: Int) async -> Bool {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return false }
        let persistence = HoloPlanningMemoryRunPersistence()
        guard let run = try? await persistence.loadRun(runID: runID) else { return false }
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard let control = try? await repository.loadControlState() else { return false }
        let guardNow = HoloContextAccessGuard(
            userDecisionVersion: control.userDecisionVersion,
            learningBaselineAt: control.learningBaselineAt,
            controls: controls
        )
        return HoloContextPlanExecutionAdapter.canSave(
            run: run,
            draftRevision: draftRevision,
            currentGuard: guardNow
        )
    }

    /// 同一 run 的追问（P8 草案卡「情况变了/补充说明」入口）。
    static func followUp(
        runID: String,
        utterance: String,
        provider: (any AIProvider)? = nil,
        onStage: ((HoloPlanningRunState) -> Void)? = nil
    ) async throws -> PlanOutcome {
        let aiProvider = provider ?? HoloBackendAIProvider()
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsPlanningInjection else {
            throw PlannerError.gateClosed
        }
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            throw PlannerError.generationUnavailable
        }
        let persistence = HoloPlanningMemoryRunPersistence()
        guard let run = try await persistence.loadRun(runID: runID) else {
            // 运行不可恢复（如重启后内存态丢失）：按新一轮处理。
            return try await plan(utterance: utterance, parentMessageID: nil, provider: aiProvider, onStage: onStage)
        }
        let updated = HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: utterance,
            referenceTime: Date()
        )
        let coordinator = Self.makeCoordinator(
            aiProvider: aiProvider,
            controls: controls,
            repository: repository,
            persistence: persistence,
            contextCountOut: ContextCountBox()
        )
        let outcome = try await coordinator.followUp(run: run, updatedFrame: updated, onStage: onStage)
        HoloPersonalContextDiagnostics.recordPlanning(
            contextCount: outcome.retrievalResult.entries.count,
            candidates: outcome.retrievalResult.entries.count,
            selected: outcome.retrievalResult.selected.count,
            coverage: outcome.retrievalResult.semanticCoverage.rawValue,
            rawFallbackUsed: outcome.rawFallbackUsed
        )
        return PlanOutcome(
            draft: outcome.draft,
            runID: outcome.run.runID,
            semanticCoverage: outcome.retrievalResult.semanticCoverage
        )
    }

    /// 云端异步规划灰度（§14.2）：内部账号先启用，观察指标后再放开生产。
    static var isCloudAsyncEnabled: Bool {
        HoloMemoryRolloutProductPolicy.current.isInternalAccount
    }

    /// 云端规划启动产物：云端任务 ID + 本机保留的检索产物（交付校验要用）。
    struct CloudPlanStart {
        let cloudTaskID: String
        let preparation: HoloContextPlanningCoordinator.PreparedPlanPrompt
        let utterance: String
    }

    /// 云端异步路径第一步：闸检查+本地检索+prompt 组装，创建云端 context_plan 任务
    /// 并上传 prompt 快照（即焚语义由服务端任务底座保证）。生成不在本机。
    static func startCloudPlan(
        utterance: String,
        parentMessageID: String?,
        provider: (any AIProvider)? = nil,
        onStage: ((HoloPlanningRunState) -> Void)? = nil,
        client: HoloCloudAnalysisClient? = nil
    ) async throws -> CloudPlanStart {
        let aiProvider = provider ?? HoloBackendAIProvider()
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsPlanningInjection else {
            logger.error("PLAN-DIAG cloud gate closed")
            HoloPersonalContextDiagnostics.recordPlanningGateClosed()
            throw PlannerError.gateClosed
        }
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            logger.error("PLAN-DIAG cloud repository unavailable")
            throw PlannerError.generationUnavailable
        }
        let persistence = HoloPlanningMemoryRunPersistence()
        let coordinator = Self.makeCoordinator(
            aiProvider: aiProvider,
            controls: controls,
            repository: repository,
            persistence: persistence,
            contextCountOut: ContextCountBox()
        )
        let frame = HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: utterance,
            referenceTime: Date()
        )
        let preparation = try await coordinator.preparePrompt(
            frame: frame,
            parentMessageID: parentMessageID,
            onStage: onStage
        )

        let cloudClient: HoloCloudAnalysisClient
        if let client {
            cloudClient = client
        } else {
            cloudClient = await HoloCloudAnalysisClient()
        }
        let start = try await cloudClient.start(question: utterance, taskType: "context_plan")
        let snapshot = try JSONSerialization.data(
            withJSONObject: ["prompt": preparation.prompt],
            options: []
        )
        try await cloudClient.uploadSnapshot(taskId: start.taskId, snapshotJSON: snapshot)
        logger.error("PLAN-DIAG cloud task started: \(start.taskId) promptChars=\(preparation.prompt.count)")
        return CloudPlanStart(cloudTaskID: start.taskId, preparation: preparation, utterance: utterance)
    }

    /// 云端异步路径第二步：领取云端产物 → 本机解析+校验+落库（真相源不外移）。
    static func deliverCloudPlan(
        _ start: CloudPlanStart,
        output: String,
        provider: (any AIProvider)? = nil
    ) async throws -> PlanOutcome {
        let aiProvider = provider ?? HoloBackendAIProvider()
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsPlanningInjection else {
            throw PlannerError.gateClosed
        }
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            throw PlannerError.generationUnavailable
        }
        let coordinator = Self.makeCoordinator(
            aiProvider: aiProvider,
            controls: controls,
            repository: repository,
            persistence: HoloPlanningMemoryRunPersistence(),
            contextCountOut: ContextCountBox()
        )
        let outcome = try await coordinator.deliverCloudOutput(start.preparation, output: output)
        HoloPersonalContextDiagnostics.recordPlanning(
            contextCount: 0,
            candidates: outcome.retrievalResult.entries.count,
            selected: outcome.retrievalResult.selected.count,
            coverage: outcome.retrievalResult.semanticCoverage.rawValue,
            rawFallbackUsed: outcome.rawFallbackUsed
        )
        return PlanOutcome(
            draft: outcome.draft,
            runID: outcome.run.runID,
            semanticCoverage: outcome.retrievalResult.semanticCoverage
        )
    }
}

/// AIProvider 四方法中的生成调用窄适配。
@MainActor
struct HoloContextPlanProviderAdapter: HoloContextPlanGenerating {
    let provider: AIProvider

    func generate(prompt: String) async throws -> String {
        try await provider.generateContextPlan(prompt: prompt, context: UserContext.empty)
    }
}

/// 聊天侧 run/draft 持久化：存消息 renderData 的桥（由 ChatViewModel 写消息载荷），
/// 这里先用 UserDefaults 轻存（run 状态恢复用），draft 随消息持久化（§8.1 checkpoint 精简）。
final class HoloPlanningMemoryRunPersistence: HoloPlanningRunPersisting, @unchecked Sendable {
    private static let key = "holo_personal_context_planning_runs_v1"

    private func loadRuns() -> [String: HoloPlanningRun] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let runs = try? JSONDecoder().decode([String: HoloPlanningRun].self, from: data)
        else { return [:] }
        return runs
    }

    private func saveRuns(_ runs: [String: HoloPlanningRun]) {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func saveRun(_ run: HoloPlanningRun) async throws {
        var runs = loadRuns()
        // 容量控制：只留最近 20 个 run。
        if runs.count >= 20 {
            let sorted = runs.values.sorted { $0.updatedAt > $1.updatedAt }
            for old in sorted.dropFirst(19) {
                runs.removeValue(forKey: old.runID)
            }
        }
        runs[run.runID] = run
        saveRuns(runs)
    }

    func loadRun(runID: String) async throws -> HoloPlanningRun? {
        loadRuns()[runID]
    }

    func saveDraft(_ draft: HoloContextPlanDraft) async throws {
        // draft 随聊天消息持久化（ChatViewModel renderData）；此处不重复存。
    }
}
