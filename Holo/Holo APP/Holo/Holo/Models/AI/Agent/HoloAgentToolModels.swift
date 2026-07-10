//
//  HoloAgentToolModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — 本地工具协议：请求 / 结果 / 度量 / 事件 / 覆盖度 / 警告
//

import Foundation

// MARK: - 工具请求

nonisolated struct HoloToolRequest: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var tool: String
    var query: String
    var timeRange: HoloAgentTimeRange?
    var baseline: HoloAgentTimeRange?
    var requiredMetrics: [String]
    var parameters: [String: String]
}

// MARK: - 结果状态与错误

nonisolated enum HoloToolResultStatus: String, Codable, CaseIterable, Sendable {
    case success
    case empty
    case partial
    case error
    case unavailable
    case timeout
}

nonisolated struct HoloToolError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var recoverable: Bool
}

nonisolated struct HoloToolWarning: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

// MARK: - 工具输出度量与事件

/// 工具输出的单个度量值（如 habit.negative.frequency_change = 20）
nonisolated struct HoloMetric: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var unit: String?
    var baselineValue: Double?
    var comparison: String?
}

/// 工具输出的事件级证据（对应原始数据点，可转为 EvidenceRecord）
nonisolated struct HoloEvidenceEvent: Codable, Equatable, Sendable {
    var id: String
    var occurredAt: Date?
    var metricKey: String?
    var metricValue: Double?
    var excerpt: String
    var timeRange: HoloAgentTimeRange? = nil
    var baselineTimeRange: HoloAgentTimeRange? = nil
}

/// 工具查询的数据覆盖度（判断结论可信度的依据）
nonisolated struct HoloDataCoverage: Codable, Equatable, Sendable {
    var coveredDays: Int
    var totalDays: Int
    var coverageRatio: Double?
    var missingRanges: [HoloAgentTimeRange]
    var note: String?
}

// MARK: - 工具结果

nonisolated struct HoloDataToolResult: Codable, Equatable, Sendable {
    var toolRequestID: String
    var tool: String
    var status: HoloToolResultStatus
    var coverage: HoloDataCoverage?
    var metrics: [HoloMetric]
    var events: [HoloEvidenceEvent]
    var warnings: [HoloToolWarning]
    var error: HoloToolError?
    /// 可选以兼容旧持久化 JSON；nil 按 normal 处理。
    var sensitivity: HoloEvidenceSensitivity? = nil
}
