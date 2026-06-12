//
//  HoloAgentResultModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 1.3 任务产物与清理策略
//

import Foundation

/// Agent 任务的最终产物：面向用户展示的洞察结论。
/// claims 引用已校验的 `HoloAgentClaim`，evidenceIDs 指向 Evidence Ledger。
struct HoloAgentResult: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var jobID: String
    var title: String
    var summary: String
    var claims: [HoloAgentClaim]
    var evidenceIDs: [String]
    var memoryCandidateIDs: [String]
    var status: String
    var generatedAt: Date
    var updatedAt: Date
}

/// Job 清理策略：终态 job 按保留期回收，可选级联清理关联的 checkpoint / result。
/// `preserveReferencedEvidence` 由 Persistence Manager（Task 1.4）解读，
/// 避免删掉仍被其它记忆/结论引用的证据。
struct HoloJobCleanupPolicy: Codable, Equatable, Sendable {
    var completedRetentionDays: Int = 30
    var failedRetentionDays: Int = 7
    var cascadeCheckpoint: Bool = true
    var cascadeResult: Bool = true
    var preserveReferencedEvidence: Bool = true
}
