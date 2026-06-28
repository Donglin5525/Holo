//
//  HoloAgentCheckpointModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — 消息与会话快照（支撑可恢复 Agent Loop）
//

import Foundation

enum HoloAgentMessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case toolResult
}

struct HoloAgentMessage: Codable, Equatable, Sendable {
    var role: HoloAgentMessageRole
    var content: String
    var toolRequestID: String?
    var toolName: String?
    var timestamp: Date
    var tokenEstimate: Int?
}

/// Agent 任务的可恢复快照：保存到某一步的全部上下文
struct HoloAgentCheckpoint: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var jobID: String
    var step: HoloAgentStep
    var completedSteps: [HoloAgentStep]
    var conversationState: [HoloAgentMessage]
    var pendingToolRequests: [HoloToolRequest]
    var completedToolResults: [HoloDataToolResult]
    var patternSignals: [HoloPatternSignal]
    var evidenceRecordIDs: [String]
    var validatedClaimIDs: [String]
    var memoryCandidateIDs: [String]
    var retryCountByStep: [String: Int]
    var createdAt: Date
    var updatedAt: Date
    /// Agent checkpoint schema 版本（1 = 初始；nil = 旧数据迁移前，解码兼容）。
    var schemaVersion: Int?
}
