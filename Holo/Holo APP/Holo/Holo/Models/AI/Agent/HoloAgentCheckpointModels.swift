//
//  HoloAgentCheckpointModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — 消息与会话快照（支撑可恢复 Agent Loop）
//

import Foundation

nonisolated enum HoloAgentMessageRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case toolResult
}

nonisolated struct HoloAgentMessage: Codable, Equatable, Sendable {
    var role: HoloAgentMessageRole
    var content: String
    var toolRequestID: String?
    var toolName: String?
    var timestamp: Date
    var tokenEstimate: Int?
}

/// Agent 任务的可恢复快照：保存到某一步的全部上下文
nonisolated struct HoloAgentCheckpoint: Codable, Identifiable, Equatable, Sendable {
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
    /// job 输入快照（HoloAgentInputSnapshot：question/timeRange/referenceDate/snapshotCutoffAt 等）
    /// 的稳定 SHA-256（§5.1），恢复时对比判断「继续还是重新规划」；
    /// 旧 Swift `Hasher` 十进制值（非 64 位 hex）为 legacy，不得用于拒绝恢复（§十 Phase 1 任务 2）。
    var inputSnapshotHash: String?
    /// checkpoint 修订号（§5.3）：每个 LLM step 的 prepared 落盘时递增，用于构造稳定 stepID。
    var revision: Int?
    /// 本 checkpoint 由哪个 execution generation 写入（§5.3，诊断用）。
    var executionGeneration: Int?
    /// 在途 LLM 请求记录（§5.3）：prepared/completed 表示请求已发起但输出未应用，
    /// 恢复后复用同一 stepID+requestHash 由后端幂等返回同一响应；applied 表示已应用不重复请求。
    var pendingLLMRequest: HoloAgentLLMRequestRecord?
}

/// LLM step 级请求记录（§5.3/§8.1）：后端按 `runID + stepID` 幂等，
/// `requestHash` 相同返回同一响应，不同返回 STEP_ID_CONFLICT。
nonisolated struct HoloAgentLLMRequestRecord: Codable, Sendable, Equatable {
    /// 所属 job（后端 runId）
    let runID: String
    /// step 标识：`llm-<轮次>-<checkpoint revision>`（后端 stepId）
    let stepID: String
    /// 本轮 messages 的 canonical SHA-256（与输入快照同规则）
    let requestHash: String
    var status: Status
    /// 响应原文的 canonical SHA-256（completed 时写入）
    var responseHash: String?

    nonisolated enum Status: String, Codable, Sendable {
        /// 已生成并落盘，请求已发起（或即将发起）
        case prepared
        /// 响应已收到并落盘，输出尚未应用
        case completed
        /// 输出已应用，不重复请求
        case applied
    }
}
