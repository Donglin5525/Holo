//
//  HoloMemorySummaryProvider.swift
//  Holo
//
//  从长期记忆 Store 中选择与当前目的相关的摘要
//  Phase 4: 支持 useScopes 筛选 + aiUseSummary + prohibitedInferences
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
        let useNewFormat = HoloAIFeatureFlags.semanticMemoryRecallEnabled
        let allowedScopes = allowedUseScopes(for: purpose)

        let allMemories = HoloLongTermMemoryStore.load()
            .filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
            .filter { mem in
                // 排除已过期的记忆
                if let expires = mem.expiresAt, expires < Date() { return false }
                return true
            }

        let selected: [HoloLongTermMemory]

        if useNewFormat {
            // 新格式：按 useScopes 筛选
            selected = selectByUseScopes(
                allMemories: allMemories,
                allowedScopes: allowedScopes,
                limit: limit
            )
        } else {
            // 旧格式：按旧 type 筛选
            selected = selectByLegacyType(
                allMemories: allMemories,
                purpose: purpose,
                limit: limit
            )
        }

        let lines = selected.map { "\($0.title)：\($0.summary)" }
        let sourceIDs = selected.map(\.id)

        let coverage: HoloMemoryCoverageLevel = selected.isEmpty
            ? .empty
            : (allMemories.count >= 3 ? .rich : .partial)

        // 构建增强条目
        let entries: [HoloMemorySummaryEntry]
        if useNewFormat {
            entries = selected.map { buildEntry($0) }
        } else {
            entries = []
        }

        return HoloMemoryPromptSummary(
            lines: lines,
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
            // 排除 displayOnly（除非明确在回顾场景）
            guard let scopes = mem.useScopes else {
                // 旧格式记忆（无 useScopes），允许通过
                return true
            }
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

    // MARK: - 旧格式筛选

    private static func selectByLegacyType(
        allMemories: [HoloLongTermMemory],
        purpose: HoloAICapabilityID?,
        limit: Int
    ) -> [HoloLongTermMemory] {
        let sorted = allMemories.sorted { $0.updatedAt > $1.updatedAt }

        switch purpose {
        case .todayState, .recentAnalysis:
            return Array(sorted
                .filter { $0.type == .recurringPattern || $0.type == .explicitUserPreference }
                .prefix(limit))
        case .longTermPatterns:
            return Array(sorted.prefix(limit))
        case .goalPlanning:
            return Array(sorted
                .filter { $0.type == .longTermGoal || $0.type == .explicitUserPreference }
                .prefix(limit))
        default:
            return Array(sorted.prefix(limit))
        }
    }

    // MARK: - Entry 构建

    private static func buildEntry(_ mem: HoloLongTermMemory) -> HoloMemorySummaryEntry {
        let aiSummary = mem.aiUseSummary
            ?? mem.displaySummary
            ?? mem.summary

        let scopeLabels = (mem.useScopes ?? [])
            .map(\.rawValue)

        let inferences = mem.prohibitedInferences ?? []

        return HoloMemorySummaryEntry(
            title: mem.title,
            aiUseSummary: aiSummary,
            useScopeLabels: scopeLabels,
            prohibitedInferences: inferences
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
