//
//  HoloAgentOutputModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — agent_loop 的 LLM JSON 输出协议
//

import Foundation

/// agent_loop 每一轮的状态：要工具 / 要继续推理 / 给出最终 claim
enum HoloAgentOutputStatus: String, Codable, CaseIterable, Sendable {
    case needTools = "need_tools"
    case needMoreAnalysis = "need_more_analysis"
    case finalClaims = "final_claims"
}

/// claim 内的度量断言（Verifier 据此比对 evidence）
struct HoloMetricAssertion: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var unit: String?
    var comparison: String?
    var evidenceIDs: [String]
}

/// Agent 的可信结论：必须挂 evidence、声明误用边界
struct HoloAgentClaim: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: String
    var displayText: String
    var metricAssertions: [HoloMetricAssertion]
    var evidenceIDs: [String]
    var prohibitedInferences: [String]
    var confidence: Double
}

/// agent_loop 单轮 JSON 输出
struct HoloAgentOutput: Codable, Equatable, Sendable {
    var status: HoloAgentOutputStatus
    var reasoning: String
    var toolRequests: [HoloToolRequest]
    var claims: [HoloAgentClaim]
    var nextStep: String?
    var warnings: [String]
}
