//
//  HoloMemorySummaryProvider.swift
//  Holo
//
//  兼容现有 Prompt 模型的摘要适配层；唯一数据来源是统一 Query Service。
//

import Foundation

enum HoloMemorySummaryProvider {
    static func selectRelevantSummary(
        purpose: HoloAICapabilityID? = nil,
        queryText: String? = nil,
        requireQueryMatch: Bool = false,
        limit: Int = 5,
        consumer: HoloMemoryAnswerConsumer? = nil,
        queryService: HoloMemoryQueryService? = nil
    ) async -> HoloMemoryPromptSummary {
        _ = requireQueryMatch
        let service: HoloMemoryQueryService
        if let queryService {
            service = queryService
        } else {
            #if HOLO_MEMORY_STANDALONE
            return emptySummary
            #else
            guard let live = try? await HoloMemoryQueryService.live() else {
                return emptySummary
            }
            service = live
            #endif
        }

        let question = queryText ?? defaultQuestion(for: purpose)
        let resolvedConsumer = consumer ?? answerConsumer(for: purpose)
        let semanticContext = semanticContext(for: purpose)
        guard let context = try? await service.query(
            question: question,
            semanticContext: semanticContext,
            consumer: resolvedConsumer,
            maxRecords: limit
        ) else {
            return emptySummary
        }
        return makeSummary(from: context)
    }

    nonisolated static func makeSummary(from context: HoloMemoryQueryContext) -> HoloMemoryPromptSummary {
        let entries = context.records.map { record in
            HoloMemorySummaryEntry(
                id: record.id,
                title: displayTitle(for: record),
                aiUseSummary: record.aiUseSummary,
                useScopeLabels: record.sourceDomains.map(\.rawValue),
                prohibitedInferences: record.prohibitedInferences
            )
        }
        let coverage: HoloMemoryCoverageLevel
        if entries.isEmpty {
            coverage = .empty
        } else if entries.count >= 3 {
            coverage = .rich
        } else {
            coverage = .partial
        }
        return HoloMemoryPromptSummary(
            sourceIDs: entries.map(\.id),
            coverage: coverage,
            entries: entries
        )
    }

    nonisolated static let emptySummary = HoloMemoryPromptSummary(
        sourceIDs: [],
        coverage: .empty,
        entries: []
    )

    private static func defaultQuestion(for purpose: HoloAICapabilityID?) -> String {
        switch purpose {
        case .todayState: return "我最近状态如何"
        case .recentAnalysis: return "分析我最近的状态"
        case .longTermPatterns: return "总结我的长期模式"
        case .goalPlanning: return "帮我规划下一步"
        case .onboarding: return "了解我的偏好"
        case nil: return "我最近状态如何"
        }
    }

    private static func semanticContext(
        for purpose: HoloAICapabilityID?
    ) -> HoloMemoryQuerySemanticContext? {
        switch purpose {
        case .goalPlanning:
            return .init(
                operation: .planning,
                domains: [.goal, .habit, .profile, .task],
                claimKinds: [],
                anchors: [],
                timeRange: nil
            )
        case .todayState, .recentAnalysis, .longTermPatterns:
            return .init(
                operation: .holistic,
                domains: [],
                claimKinds: [],
                anchors: [],
                timeRange: nil
            )
        case .onboarding:
            return .init(
                operation: .summary,
                domains: [.profile],
                claimKinds: [.explicitPreference, .lifeEvent],
                anchors: [],
                timeRange: nil
            )
        case nil:
            return nil
        }
    }

    private static func answerConsumer(
        for purpose: HoloAICapabilityID?
    ) -> HoloMemoryAnswerConsumer {
        switch purpose {
        case .todayState: return .capabilityTodayState
        case .recentAnalysis: return .capabilityRecentAnalysis
        case .longTermPatterns: return .capabilityLongTermPatterns
        case .goalPlanning: return .capabilityGoalPlanning
        case .onboarding: return .capabilityOnboarding
        case nil: return .chat
        }
    }

    nonisolated private static func displayTitle(for record: HoloMemoryRecord) -> String {
        if record.scope == .crossDomain { return "跨域观察" }
        switch record.primaryDomain {
        case .finance: return "财务记忆"
        case .thought: return "观点记忆"
        case .health: return "健康记忆"
        case .habit: return "习惯记忆"
        case .task: return "任务记忆"
        case .goal: return "目标记忆"
        case .conversation: return "对话记忆"
        case .profile: return "个人记忆"
        case nil: return "记忆"
        }
    }
}
