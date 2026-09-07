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

    /// 从聊天请求生成情境方案草案（只读，不写业务事项）。
    /// - Parameters:
    ///   - utterance: 用户本轮原话。
    ///   - parentMessageID: 关联聊天消息（run 跟随追问）。
    ///   - provider: AI Provider（默认后端）。
    static func plan(
        utterance: String,
        parentMessageID: String?,
        provider: (any AIProvider)? = nil
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
        let coordinator = HoloContextPlanningCoordinator(
            generator: HoloContextPlanProviderAdapter(provider: aiProvider),
            retrieval: HoloContextRetrievalService(semanticProvider: nil),
            persistence: persistence,
            recordsProvider: {
                // 候选记录来自本机情境库（personalContext 载荷）。
                let records = (try? await repository.query(.all)) ?? []
                let contexts = records.filter { $0.personalContext != nil }
                logger.error("PLAN-DIAG records=\(records.count) contexts=\(contexts.count)")
                return contexts
            },
            controlSnapshotProvider: {
                let control = try await repository.loadControlState()
                return HoloContextAccessGuard(
                    userDecisionVersion: control.userDecisionVersion,
                    learningBaselineAt: control.learningBaselineAt,
                    controls: controls
                )
            }
        )

        let outcome = try await coordinator.start(
            frame: frame,
            parentMessageID: parentMessageID
        )
        logger.error("PLAN-DIAG start ok: run=\(outcome.run.runID) draftItems=\(outcome.draft.items.count) answerLen=\(outcome.draft.answerText.count) entries=\(outcome.retrievalResult.entries.count) selected=\(outcome.retrievalResult.selected.count) coverage=\(outcome.retrievalResult.semanticCoverage.rawValue)")
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
        let persistence = HoloPlanningMemoryRunPersistence()
        guard let run = try await persistence.loadRun(runID: runID) else {
            // 运行不可恢复（如重启后内存态丢失）：按新一轮处理。
            return try await plan(utterance: utterance, parentMessageID: nil, provider: aiProvider)
        }
        let updated = HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: utterance,
            referenceTime: Date()
        )
        let coordinator = HoloContextPlanningCoordinator(
            generator: HoloContextPlanProviderAdapter(provider: aiProvider),
            retrieval: HoloContextRetrievalService(semanticProvider: nil),
            persistence: persistence,
            recordsProvider: {
                let records = (try? await repository.query(.all)) ?? []
                return records.filter { $0.personalContext != nil }
            },
            controlSnapshotProvider: {
                let control = try await repository.loadControlState()
                return HoloContextAccessGuard(
                    userDecisionVersion: control.userDecisionVersion,
                    learningBaselineAt: control.learningBaselineAt,
                    controls: controls
                )
            }
        )
        let outcome = try await coordinator.followUp(run: run, updatedFrame: updated)
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
