//
//  HoloAgentJobModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Agent 任务与预算
//

import Foundation

nonisolated enum HoloAgentJobType: String, Codable, CaseIterable, Sendable {
    case deepAnalysis
    case memoryGallerySummary
    case observerInspection
    case memoryCuration
    case healthInsight
    case debugMock
}

nonisolated enum HoloAgentTrigger: String, Codable, CaseIterable, Sendable {
    case userQuestion
    case memoryGalleryRefresh
    case observerTier2
    case healthInsight
    case debug
}

nonisolated enum HoloAgentJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingForLLM
    case retrying
    case waitingForForeground
    case paused
    case completed
    case failed
    case cancelled
}

nonisolated enum HoloAgentStep: String, Codable, CaseIterable, Sendable {
    case plan
    case executeTools
    case minePatterns
    case integrateResults
    case continueOrConclude
    case verifyClaims
    case critique
    case curateMemory
    case render
    case persistResult
}

// MARK: - 任务

nonisolated struct HoloAgentJob: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: HoloAgentJobType
    var userQuestion: String?
    var trigger: HoloAgentTrigger
    var state: HoloAgentJobState
    var currentStep: HoloAgentStep
    var createdAt: Date
    var updatedAt: Date
    var lastForegroundRunAt: Date?
    var timeRange: HoloAgentTimeRange?
    var budget: HoloAgentBudget
    var checkpointID: String?
    var resultID: String?
    var errorSummary: String?
    var deviceID: String?
    var sourceMessageID: UUID? = nil
}

// MARK: - 预算

nonisolated struct HoloAgentBudget: Codable, Equatable, Sendable {
    var maxLLMRounds: Int
    var maxToolBatches: Int
    var maxInputTokens: Int
    var maxOutputTokens: Int
    var maxWallTimeSeconds: Int
    var consumedLLMRounds: Int
    var consumedToolBatches: Int
    var consumedInputTokens: Int
    var consumedOutputTokens: Int
    var startedAt: Date
    var updatedAt: Date

    var isExhausted: Bool {
        consumedLLMRounds >= maxLLMRounds ||
            consumedToolBatches >= maxToolBatches ||
            consumedInputTokens >= maxInputTokens ||
            consumedOutputTokens >= maxOutputTokens ||
            Date().timeIntervalSince(startedAt) >= TimeInterval(maxWallTimeSeconds)
    }
}

extension HoloAgentBudget {
    /// 标准深度分析预算
    static func normalDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 5, maxToolBatches: 5,
            maxInputTokens: 10_000, maxOutputTokens: 4_000,
            maxWallTimeSeconds: 120,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }

    /// 扩展深度分析预算（用户主动继续时）
    static func extendedDeep(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 5, maxToolBatches: 5,
            maxInputTokens: 20_000, maxOutputTokens: 8_000,
            maxWallTimeSeconds: 300,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }

    /// Observer Tier2 跟进预算（更克制）
    static func observerFollowUp(now: Date = Date()) -> HoloAgentBudget {
        HoloAgentBudget(
            maxLLMRounds: 2, maxToolBatches: 2,
            maxInputTokens: 6_000, maxOutputTokens: 2_000,
            maxWallTimeSeconds: 60,
            consumedLLMRounds: 0, consumedToolBatches: 0,
            consumedInputTokens: 0, consumedOutputTokens: 0,
            startedAt: now, updatedAt: now
        )
    }
}
