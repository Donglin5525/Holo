//
//  HoloEvidenceModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — Evidence Ledger：本地证据账本，支撑可信 claim 校验
//

import Foundation

nonisolated enum HoloEvidenceSourceModule: String, Codable, CaseIterable, Sendable {
    case finance
    case habit
    case task
    case goal
    case thought
    case health
    case memory
    case profile
    case agent
}

nonisolated enum HoloEvidenceStatus: String, Codable, CaseIterable, Sendable {
    case active
    case partial
    case orphaned
    case archived
}

nonisolated enum HoloEvidenceSensitivity: String, Codable, CaseIterable, Sendable {
    case normal
    case highImpact
    case sensitive
}

nonisolated struct HoloEvidenceRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var dedupeKey: String
    var sourceModule: HoloEvidenceSourceModule
    var sourceID: String?
    var sourceKind: String
    var timeRange: HoloAgentTimeRange?
    var occurredAt: Date?
    var metricKey: String
    var metricValue: Double?
    var unit: String?
    var baselineValue: Double?
    var baselineTimeRange: HoloAgentTimeRange? = nil
    var comparison: String?
    var excerpt: String
    /// 脱敏摘要，默认发给 LLM；完整 excerpt 仅本地 Verifier 使用
    var redactedExcerpt: String
    var sensitivity: HoloEvidenceSensitivity
    var confidence: Double
    var status: HoloEvidenceStatus
    var generatedBy: String
    var generatedAt: Date
    var referencedByJobIDs: [String]
    var referencedByMemoryIDs: [String]
    var deviceID: String?
}
