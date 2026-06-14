//
//  HoloInsightCritic.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.2 Insight Critic
//  过滤低价值 claim：空话鼓励词、无证据 claim、纯统计无实质变化的 claim。
//  只保留有 evidence 支撑、表达具体观察的 claim。
//

import Foundation

struct HoloInsightCritic {

    /// 空话/鼓励词：含这些词的 claim 通常无实质信息，过滤。
    static let fillerPhrases: [String] = [
        "继续保持", "注意控制", "节奏不错", "再接再厉", "加油", "保持下去", "继续保持"
    ]

    /// 过滤低价值 claim，保留有 evidence 支撑的实质 claim。
    func filter(_ claims: [HoloAgentClaim], patterns: [HoloPatternSignal]) -> [HoloAgentClaim] {
        claims.filter { claim in
            // 1. 空话词
            for phrase in Self.fillerPhrases where claim.displayText.contains(phrase) {
                return false
            }
            // 2. 必须有 evidence（顶层或 metricAssertion 内）
            let hasEvidence = !claim.evidenceIDs.isEmpty
                || claim.metricAssertions.contains { !$0.evidenceIDs.isEmpty }
            return hasEvidence
        }
    }
}
