//
//  HoloAgentResultModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 1.3 任务产物与清理策略
//

import Foundation

/// Agent 任务的最终产物：面向用户展示的洞察结论。
/// claims 引用已校验的 `HoloAgentClaim`，evidenceIDs 指向 Evidence Ledger。
nonisolated struct HoloAgentResult: Codable, Identifiable, Equatable, Sendable {
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
    /// 本轮答案实际采用的数据覆盖；旧结果缺失时为 nil。
    var coverage: HoloDataCoverage? = nil
    /// 当 claims 为空时，记录原因。用于 UI 区分"确实没数据"与"有数据但未通过校验"，
    /// 避免一律显示"数据不足"的误导文案。旧结果反序列化时为 nil。
    var emptyReason: HoloAgentEmptyReason? = nil
}

/// 空结论的原因。区分两类失败，用于精准提示用户。
nonisolated enum HoloAgentEmptyReason: String, Codable, Sendable {
    /// 工具在所选时间范围内确实没有返回可用数据。
    case noData
    /// 工具返回了数据，但 claim 未通过 Verifier 校验（如证据不足、表达越界）。
    case unverifiable
}

/// Job 清理策略：终态 job 按保留期回收，可选级联清理关联的 checkpoint / result。
/// `preserveReferencedEvidence` 由 Persistence Manager（Task 1.4）解读，
/// 避免删掉仍被其它记忆/结论引用的证据。
nonisolated struct HoloJobCleanupPolicy: Codable, Equatable, Sendable {
    var completedRetentionDays: Int = 30
    var failedRetentionDays: Int = 7
    var cascadeCheckpoint: Bool = true
    var cascadeResult: Bool = true
    var preserveReferencedEvidence: Bool = true
}
