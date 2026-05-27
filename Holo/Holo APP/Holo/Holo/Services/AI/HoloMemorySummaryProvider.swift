//
//  HoloMemorySummaryProvider.swift
//  Holo
//
//  从长期记忆 Store 中选择与当前目的相关的摘要
//

import Foundation

enum HoloMemorySummaryProvider {

    /// 选择与当前用途相关的记忆摘要
    static func selectRelevantSummary(purpose: HoloAICapabilityID? = nil, limit: Int = 5) -> HoloMemoryPromptSummary {
        let allMemories = HoloLongTermMemoryStore.load()
            .filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
            .sorted { $0.updatedAt > $1.updatedAt }

        let selected: [HoloLongTermMemory]
        switch purpose {
        case .todayState, .recentAnalysis:
            // 今日/近期分析优先选重复模式和偏好
            selected = Array(allMemories
                .filter { $0.type == .recurringPattern || $0.type == .explicitUserPreference }
                .prefix(limit))
        case .longTermPatterns:
            // 长期模式选全部类型
            selected = Array(allMemories.prefix(limit))
        case .goalPlanning:
            // 目标规划优先选长期目标和执行偏好
            selected = Array(allMemories
                .filter { $0.type == .longTermGoal || $0.type == .explicitUserPreference }
                .prefix(limit))
        default:
            selected = Array(allMemories.prefix(limit))
        }

        let lines = selected.map { "\($0.title)：\($0.summary)" }
        let sourceIDs = selected.map(\.id)

        let coverage: HoloMemoryCoverageLevel = selected.isEmpty
            ? .empty
            : (allMemories.count >= 3 ? .rich : .partial)

        return HoloMemoryPromptSummary(
            lines: lines,
            sourceIDs: sourceIDs,
            coverage: coverage
        )
    }
}
