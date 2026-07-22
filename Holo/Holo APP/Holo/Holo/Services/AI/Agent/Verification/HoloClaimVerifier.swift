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
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                                     evidenceByID: [String: HoloEvidenceRecord]) -> String? {
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
                guard let record = evidenceByID[evidenceID] else {
                    return "evidenceID 不存在：\(evidenceID)"
                }
                if record.metricKey != assertion.metricKey {
                    return "metricKey 不匹配：claim=\(assertion.metricKey) evidence=\(record.metricKey)"
                }
                if let value = assertion.value, let evidenceValue = record.metricValue,
                   abs(value - evidenceValue) > 0.01 {
                    return "value 不一致：claim=\(value) evidence=\(evidenceValue)"
                }
            }
        }
        return nil
    }
}
