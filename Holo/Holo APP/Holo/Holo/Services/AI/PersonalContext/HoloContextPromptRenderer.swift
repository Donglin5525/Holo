//
//  HoloContextPromptRenderer.swift
//  Holo
//
//  三入口统一的个人情境上下文渲染（实施方案 §9.4）。
//
//  - 目标规划/Agent 共享同一渲染：advice 政策筛选 → 混合检索 → ≤8 条
//    真正影响方案的情境，推断类带限定表达。
//  - 闸关闭/无情境时返回 nil，调用方保持原行为（零破坏）。
//  - 同一来源只出现一次（去重由检索合并保证）；不露内部评分。
//

import Foundation

@MainActor
enum HoloContextPromptRenderer {
    /// 渲染共享情境块；闸关或无可用情境返回 nil。
    /// - Parameters:
    ///   - goalSummary: 检索方向来源（目标一句话）。
    ///   - repository: 记忆仓储（默认运行时仓库）。
    static func render(
        goalSummary: String,
        repository: (any HoloMemoryRepository)? = nil
    ) async -> String? {
        await renderInternal(goalSummary: goalSummary, repository: repository)
    }

    private static func renderInternal(
        goalSummary: String,
        repository: (any HoloMemoryRepository)?
    ) async -> String? {
        let controls = HoloPersonalContextControls.resolve(
            defaults: .standard,
            isInternalAccount: HoloMemoryRolloutProductPolicy.current.isInternalAccount,
            automaticMemoryEnabled: HoloMemorySettings.shared.automaticMemoryEnabled,
            memoryAssistedAnsweringEnabled: HoloMemorySettings.shared.memoryAssistedAnsweringEnabled,
            aiDataProcessingConsentGranted: HoloAIDataProcessingConsent.shared.isGranted
        )
        guard controls.allowsPlanningInjection else { return nil }

        let repo: (any HoloMemoryRepository)?
        if let repository {
            repo = repository
        } else {
            repo = try? await HoloMemoryRuntime.shared.repository()
        }
        guard let repo else { return nil }
        let records = ((try? await repo.query(.all)) ?? []).filter { $0.personalContext != nil }
        guard !records.isEmpty else { return nil }

        let policy = HoloContextAccessPolicy.selectAdviceCandidates(records: records)
        guard !policy.selected.isEmpty else { return nil }

        let frame = HoloPlanningRequestFrame(
            utterance: goalSummary,
            goalSummary: goalSummary,
            referenceTime: Date()
        )
        let retrieval = HoloContextRetrievalService(semanticProvider: nil)
        let result = await retrieval.retrieve(
            frame: frame,
            catalog: policy.selected,
            calendar: .current,
            now: Date()
        )
        let selected = result.selected
        guard !selected.isEmpty else { return nil }

        var lines: [String] = []
        for entry in selected {
            var line = "- \(entry.payload.statement)"
            if let temporal = entry.payload.temporal {
                line += "（\(temporal.originalExpression)）"
            }
            if let condition = entry.payload.applicability.conditionText, !condition.isEmpty {
                line += "［范围：\(condition)］"
            }
            if entry.currentOccurrenceStatus == .done {
                line += "（本周期已完成）"
            }
            lines.append(line)
        }
        return """
        【用户个人情境】（来自用户记录，推断项已带限定表达；仅供参考，不得当作已确认事实）
        \(lines.joined(separator: "\n"))
        """
    }
}
