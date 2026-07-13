//
//  HoloShortTermMemoryModels.swift
//  Holo
//
//  短期记忆模型：单次流程内快照，不跨会话缓存
//

import Foundation

enum HoloMemoryCoverageLevel: String, Codable, Equatable {
    case rich
    case partial
    case empty
}

struct HoloMemoryDataCoverage: Codable, Equatable {
    var level: HoloMemoryCoverageLevel
    var availableSources: [HoloMemorySource]
    var missingSources: [HoloMemorySource]
    var reason: String

    static let empty = HoloMemoryDataCoverage(
        level: .empty,
        availableSources: [],
        missingSources: HoloMemorySource.allCases,
        reason: "暂无任何数据"
    )
}

enum HoloMemorySource: String, Codable, CaseIterable, Equatable {
    case finance
    case tasks
    case habits
    case thoughts
    case goals
    case health
    case profile
    case conversation
    case memoryInsight
}

struct HoloShortTermMemorySnapshot: Codable, Equatable {
    var generatedAt: Date
    var window: HoloMemoryWindow
    var dataCoverage: HoloMemoryDataCoverage
    var sourceSummary: [HoloMemorySourceSummary]
    var recentSignals: [HoloRecentSignal]
    var activeGoalSummary: String?
    var recentConversationIntent: String?
    var relevantLongTermMemorySummary: HoloMemoryPromptSummary?
}

enum HoloMemoryWindow: String, Codable, Equatable {
    case today
    case sevenDays
    case fourteenDays
    case thirtyDays
}

struct HoloMemorySourceSummary: Codable, Equatable {
    var source: HoloMemorySource
    var count: Int
    var latestAt: Date?
}

struct HoloRecentSignal: Codable, Equatable, Identifiable {
    var id: String
    var source: HoloMemorySource
    var title: String
    var detail: String
    var occurredAt: Date?
}

/// 单条记忆摘要的增强信息（Phase 4 新增）
struct HoloMemorySummaryEntry: Codable, Equatable {
    var id: String
    var title: String
    var aiUseSummary: String
    var useScopeLabels: [String]
    var prohibitedInferences: [String]
}

struct HoloMemoryPromptSummary: Codable, Equatable {
    var sourceIDs: [String]
    var coverage: HoloMemoryCoverageLevel
    var entries: [HoloMemorySummaryEntry]

    static let empty = HoloMemoryPromptSummary(sourceIDs: [], coverage: .empty, entries: [])
}
