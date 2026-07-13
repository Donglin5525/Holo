//
//  HoloMemorySummaryProvider.swift
//  Holo
//
//  从长期记忆 Store 中选择与当前目的相关的摘要
//  仅使用严格 V2 记忆：useScopes + aiUseSummary + prohibitedInferences
//

import Foundation

enum HoloMemorySummaryProvider {

    /// 选择与当前用途相关的记忆摘要
    /// - Parameters:
    ///   - purpose: AI 能力场景，决定允许的 useScopes
    ///   - limit: 最大条数
    static func selectRelevantSummary(
        purpose: HoloAICapabilityID? = nil,
        limit: Int = 5
    ) -> HoloMemoryPromptSummary {
        let allowedScopes = allowedUseScopes(for: purpose)

        let allMemories = HoloLongTermMemoryStore.load()
            .filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
            .filter { mem in
                // 排除已过期的记忆
                if let expires = mem.expiresAt, expires < Date() { return false }
                return true
            }

        let selected = selectByUseScopes(
            allMemories: allMemories,
            allowedScopes: allowedScopes,
            limit: limit
        )
        let sourceIDs = selected.map(\.id)

        let coverage: HoloMemoryCoverageLevel = selected.isEmpty
            ? .empty
            : (allMemories.count >= 3 ? .rich : .partial)

        let entries = selected.map { buildEntry($0) }

        return HoloMemoryPromptSummary(
            sourceIDs: sourceIDs,
            coverage: coverage,
            entries: entries
        )
    }

    // MARK: - UseScope 筛选

    private static func allowedUseScopes(for purpose: HoloAICapabilityID?) -> Set<HoloMemoryUseScope> {
        switch purpose {
        case .todayState, .recentAnalysis:
            return [.coreContext, .recentInsight]
        case .longTermPatterns:
            return [.coreContext, .recentInsight, .goalPlanning, .retrospective]
        case .goalPlanning:
            return [.coreContext, .goalPlanning]
        default:
            // chat 和未指定场景
            return [.coreContext, .recentInsight]
        }
    }

    private static func selectByUseScopes(
        allMemories: [HoloLongTermMemory],
        allowedScopes: Set<HoloMemoryUseScope>,
        limit: Int
    ) -> [HoloLongTermMemory] {
        let filtered = allMemories.filter { mem in
            let scopes = mem.useScopes
            // displayOnly 且不在回顾场景 → 排除
            if scopes.contains(.displayOnly) && !allowedScopes.contains(.retrospective) {
                return false
            }
            // 至少一个 scope 在允许集合中
            let effectiveScopes = Set(scopes.filter { $0 != .displayOnly })
            return !effectiveScopes.isEmpty
                ? !effectiveScopes.intersection(allowedScopes).isEmpty
                : false
        }

        // 排序：高置信 > 近期更新 > 非敏感 > 证据多
        return Array(filtered.sorted { mem1, mem2 in
            if confidenceOrder(mem1.confidence) != confidenceOrder(mem2.confidence) {
                return confidenceOrder(mem1.confidence) < confidenceOrder(mem2.confidence)
            }
            if mem1.updatedAt != mem2.updatedAt {
                return mem1.updatedAt > mem2.updatedAt
            }
            if sensitivityOrder(mem1.sensitivity) != sensitivityOrder(mem2.sensitivity) {
                return sensitivityOrder(mem1.sensitivity) < sensitivityOrder(mem2.sensitivity)
            }
            return mem1.evidence.count > mem2.evidence.count
        }.prefix(limit))
    }

    // MARK: - Entry 构建

    private static func buildEntry(_ mem: HoloLongTermMemory) -> HoloMemorySummaryEntry {
        return HoloMemorySummaryEntry(
            id: mem.id,
            title: mem.title,
            aiUseSummary: mem.aiUseSummary,
            useScopeLabels: mem.useScopes.map(\.rawValue),
            prohibitedInferences: mem.prohibitedInferences
        )
    }

    // MARK: - 排序辅助

    private static func confidenceOrder(_ c: HoloMemoryConfidence) -> Int {
        switch c {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private static func sensitivityOrder(_ s: HoloMemorySensitivity) -> Int {
        switch s {
        case .normal: return 0
        case .highImpact: return 1
        case .sensitive: return 2
        }
    }
}
