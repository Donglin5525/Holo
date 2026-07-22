//
//  HoloClaimVerifier.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.1 Claim 校验器
//  确定性校验：每个 metricAssertion 必须有存在的 evidence、metricKey 匹配、value 一致；
//  claim 文案不得包含因果词（导致/证明/说明一定因为）。只校验结构化字段，不解析自然语言。
//

import Foundation

/// 被拒绝的 claim 及原因。
struct HoloRejectedClaim: Equatable, Sendable {
    var claim: HoloAgentClaim
    var reason: String
}

/// Claim 校验结果。
struct HoloClaimVerificationResult: Equatable, Sendable {
    var acceptedClaims: [HoloAgentClaim]
    var rejectedClaims: [HoloRejectedClaim]
}

nonisolated struct HoloClaimVerifier {

    /// 禁止的因果词：claim 文案不得用因果断言，只能描述并发。
    static let causalWords: [String] = ["导致", "证明", "说明一定因为"]

    /// 校验 claims 是否有 evidence 支撑、字段一致、文案合规。
    func verify(claims: [HoloAgentClaim], evidence: [HoloEvidenceRecord]) -> HoloClaimVerificationResult {
        let evidenceByID = Dictionary(grouping: evidence, by: \.id)
        var accepted: [HoloAgentClaim] = []
        var rejected: [HoloRejectedClaim] = []

        for claim in claims {
            if let reason = Self.rejectReason(for: claim, evidenceByID: evidenceByID) {
                rejected.append(HoloRejectedClaim(claim: claim, reason: reason))
            } else {
                accepted.append(claim)
            }
        }
        return HoloClaimVerificationResult(acceptedClaims: accepted, rejectedClaims: rejected)
    }

    private static func rejectReason(for claim: HoloAgentClaim,
                                     evidenceByID: [String: [HoloEvidenceRecord]]) -> String? {
        // 1. 文案因果词
        for word in causalWords where claim.displayText.contains(word) {
            return "文案包含因果词「\(word)」，只能描述并发"
        }
        // 2. 所有对外展示的 claim 都必须有结构化证据，不能只靠模型文字。
        guard !claim.metricAssertions.isEmpty else {
            return "claim 缺少 metricAssertions"
        }
        guard claim.metricAssertions.contains(where: { !$0.evidenceIDs.isEmpty }) else {
            return "claim 缺少 evidenceIDs"
        }
        // 3. metricAssertions 逐条校验
        for assertion in claim.metricAssertions {
            guard !assertion.evidenceIDs.isEmpty else {
                return "metricAssertion 缺少 evidenceIDs：\(assertion.metricKey)"
            }
            for evidenceID in assertion.evidenceIDs {
                guard let records = evidenceByID[evidenceID], let record = records.first else {
                    return "evidenceID 不存在：\(evidenceID)"
                }
                if records.dropFirst().contains(where: { !evidenceEquivalent(record, $0) }) {
                    return "evidenceID 存在冲突记录：\(evidenceID)"
                }
                guard record.status == .active || record.status == .partial else {
                    return "evidence 已失效：\(evidenceID)"
                }
                if record.metricKey != assertion.metricKey {
                    return "metricKey 不匹配：claim=\(assertion.metricKey) evidence=\(record.metricKey)"
                }
                if let value = assertion.value {
                    guard let evidenceValue = record.metricValue else {
                        return "evidence 缺少断言所需 value：\(evidenceID)"
                    }
                    if !valuesMatch(value, evidenceValue) {
                        return "value 不一致：claim=\(value) evidence=\(evidenceValue)"
                    }
                }
                if let baseline = assertion.baselineValue {
                    guard let evidenceBaseline = record.baselineValue else {
                        return "evidence 缺少断言所需 baselineValue：\(evidenceID)"
                    }
                    if !valuesMatch(baseline, evidenceBaseline) {
                        return "baselineValue 不一致：claim=\(baseline) evidence=\(evidenceBaseline)"
                    }
                }
                if let unit = assertion.unit, record.unit != unit {
                    return "unit 不一致：claim=\(unit) evidence=\(record.unit ?? "nil")"
                }
                if let comparison = assertion.comparison, record.comparison != comparison {
                    return "comparison 不一致：claim=\(comparison) evidence=\(record.comparison ?? "nil")"
                }
            }
        }
        return nil
    }

    private static func valuesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        let tolerance = max(0.000_001, max(abs(lhs), abs(rhs)) * 0.000_001)
        return abs(lhs - rhs) <= tolerance
    }

    private static func evidenceEquivalent(_ lhs: HoloEvidenceRecord,
                                           _ rhs: HoloEvidenceRecord) -> Bool {
        lhs.metricKey == rhs.metricKey
            && optionalValuesMatch(lhs.metricValue, rhs.metricValue)
            && optionalValuesMatch(lhs.baselineValue, rhs.baselineValue)
            && lhs.unit == rhs.unit
            && lhs.comparison == rhs.comparison
            && lhs.status == rhs.status
    }

    private static func optionalValuesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case let (.some(left), .some(right)): valuesMatch(left, right)
        default: false
        }
    }
}
