//
//  HoloEpisodicMemoryModels.swift
//  Holo
//
//  短期（情景）记忆模型：观察、活跃、提升候选、过期状态机
//

import Foundation

// MARK: - Visibility

enum HoloMemoryVisibility: String, Codable, Equatable {
    case hidden
    case suggested
    case reviewRequired
}

// MARK: - State Machine

enum HoloEpisodicMemoryState: String, Codable, Equatable {
    case observing
    case active
    case suggested
    case promotionCandidate
    case promoted
    case rejected
    case expired
    case archived
}

// MARK: - Episodic Memory

struct HoloEpisodicMemory: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var state: HoloEpisodicMemoryState
    var visibility: HoloMemoryVisibility
    var confidence: HoloMemoryConfidence
    var sensitivity: HoloMemorySensitivity
    var hitCount: Int
    var semanticHitRunIDs: [String]
    var evidence: [HoloLongTermMemoryEvidence]
    var createdAt: Date
    var updatedAt: Date
    var lastHitAt: Date?
    var expiresAt: Date
    var sourceModules: [HoloMemorySource]
    var reasoningSummary: String?
    var userEditedSummary: String?
    var promotedLongTermMemoryID: String?

    // 审计
    var createdFromRunID: String?
    var schemaVersion: Int = 1
}

// MARK: - Signal

enum HoloMemorySignalPolarity: String, Codable, Equatable {
    case positive
    case negative
    case mixed
}

struct HoloMemorySignal: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var polarity: HoloMemorySignalPolarity
    var confidence: Double
    var sourceModule: HoloMemorySource
    var evidenceRefs: [String]
    var generatedAt: Date
}

// MARK: - Suppression Rule

struct HoloMemorySuppressionRule: Codable, Equatable, Identifiable {
    var id: String
    var originalMemorySummary: String
    var keywordGroups: [[String]]
    var suppressedUntil: Date
    var originalRejectedAt: Date
}
