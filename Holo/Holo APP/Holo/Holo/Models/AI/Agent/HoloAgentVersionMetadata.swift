//
//  HoloAgentVersionMetadata.swift
//  Holo
//
//  Agent 成熟度演进 P0-D — 版本语义拆分
//
//  拆分三类版本：
//    - promptRevision：复用现有 PromptManager 的版本表
//    - agentProtocolVersion：回答契约结构版本（当前 v10）
//    - toolSchemaVersion：工具目录版本（需补建，当前固定 1）
//  数据库历史版本保留为内部审计，不作为客户端兼容版本。
//

import Foundation

nonisolated struct HoloAgentVersionMetadata: Equatable, Sendable, Codable {
    /// Prompt 版本（复用 PromptManager.promptVersions[.agentLoop]）。
    var promptRevision: Int
    /// Agent 回答契约结构版本（当前 v10）。
    var agentProtocolVersion: Int
    /// 工具目录版本（当前固定 1，工具语义变化时递增）。
    var toolSchemaVersion: Int

    static let current = HoloAgentVersionMetadata(
        promptRevision: 10,        // agent_loop v10
        agentProtocolVersion: 10,  // V10 回答契约
        toolSchemaVersion: 1       // 当前无独立目录版本概念
    )

    /// 版本元数据的可观测性摘要（非敏感）。
    var observabilitySummary: [String: Any] {
        [
            "promptRevision": promptRevision,
            "agentProtocolVersion": agentProtocolVersion,
            "toolSchemaVersion": toolSchemaVersion
        ]
    }
}
