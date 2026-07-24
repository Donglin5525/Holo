//
//  HoloClaimVerifierV2Tests.swift
//  HoloTests
//
//  Agent 成熟度演进 P0-C — Claim Verifier 2.0 测试
//

import Foundation

@main
struct HoloClaimVerifierV2Tests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test正常claim_通过()
        test因果越界_拒绝()
        test无evidence_拒绝()
        testmetricKey不匹配_拒绝()
        testvalue不一致_拒绝()
        test单位不一致_降级()
        test分母为零_拒绝()
        test弱证据强表达_降级()
        test相关性claim单域_降级()
        test重复血缘_降级()
        test模型置信度过高_降级()
        test系统置信度计算_不受模型影响()
        test降级文案含披露()
        test三态输出完整性()
        print("HoloClaimVerifierV2Tests passed")
    }

    // MARK: - Helpers

    private static func makeEvidence(
        id: String, metricKey: String = "finance.total", value: Double = 3000, unit: String = "元",
        sourceModule: HoloEvidenceSourceModule = .finance, confidence: Double = 0.9,
        status: HoloEvidenceStatus = .active, dedupeKey: String? = nil, baselineValue: Double? = nil
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: dedupeKey ?? "dk-\(id)", sourceModule: sourceModule,
            sourceID: "src-\(id)", sourceKind: "aggregate",
            timeRange: HoloAgentTimeRange(label: "本月", start: nil, end: nil),
            occurredAt: nil, metricKey: metricKey, metricValue: value, unit: unit,
            baselineValue: baselineValue, comparison: nil, formula: nil, sourceRecordIDs: ["r1", "r2"],
            excerpt: "[test]", redactedExcerpt: "[test]",
            sensitivity: .normal, confidence: confidence, status: status,
            generatedBy: "test", generatedAt: Date(),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func makeClaim(
        id: String = "claim1", type: String = "observation", text: String = "本月消费3000元",
        metricKey: String = "finance.total", value: Double = 3000, unit: String = "元",
        evidenceIDs: [String] = ["ev1"], confidence: Double = 0.8,
        baselineValue: Double? = nil, comparison: String? = nil
    ) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id, type: type, displayText: text,
            metricAssertions: [HoloMetricAssertion(metricKey: metricKey, value: value, baselineValue: baselineValue, unit: unit, comparison: comparison, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [],
            confidence: confidence
        )
    }

    // MARK: - 测试

    private static func test正常claim_通过() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(),
            evidence: [makeEvidence(id: "ev1")]
        )
        expect(result.verdict == .verified, "正常 claim 应通过，实际 \(result.verdict)，reasons: \(result.reasons)")
        expect(result.systemConfidence > 0.5, "系统置信度应 > 0.5，实际 \(result.systemConfidence)")
    }

    private static func test因果越界_拒绝() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(text: "睡眠不足导致焦虑", metricKey: "health.sleep", value: 5, unit: "小时", evidenceIDs: ["ev1"]),
            evidence: [makeEvidence(id: "ev1", metricKey: "health.sleep", value: 5, unit: "小时", sourceModule: .health)]
        )
        expect(result.verdict == .rejected, "因果越界应拒绝，实际 \(result.verdict)")
    }

    private static func test无evidence_拒绝() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(evidenceIDs: []),
            evidence: []
        )
        expect(result.verdict == .rejected, "无 evidence 应拒绝，实际 \(result.verdict)")
    }

    private static func testmetricKey不匹配_拒绝() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(metricKey: "finance.total", evidenceIDs: ["ev1"]),
            evidence: [makeEvidence(id: "ev1", metricKey: "health.steps", value: 8000, unit: "步", sourceModule: .health)]
        )
        expect(result.verdict == .rejected, "metricKey 不匹配应拒绝，实际 \(result.verdict)")
    }

    private static func testvalue不一致_拒绝() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(value: 3000),
            evidence: [makeEvidence(id: "ev1", value: 5000)]
        )
        expect(result.verdict == .rejected, "value 不一致应拒绝，实际 \(result.verdict)")
    }

    private static func test单位不一致_降级() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(value: 3000, unit: "美元"),
            evidence: [makeEvidence(id: "ev1", value: 3000, unit: "元")]
        )
        expect(result.verdict == .degraded, "单位不一致应降级，实际 \(result.verdict)")
        expect(result.degradedExpression != nil, "降级应有文案")
    }

    private static func test分母为零_拒绝() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(value: 100, baselineValue: 0, comparison: "percentage"),
            evidence: [makeEvidence(id: "ev1", value: 100, baselineValue: 0)]
        )
        expect(result.verdict == .rejected, "分母为零应拒绝，实际 \(result.verdict)")
    }

    private static func test弱证据强表达_降级() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(type: "causal", text: "运动改善睡眠", metricKey: "health.sleep", value: 7, unit: "小时", evidenceIDs: ["ev1"], confidence: 0.9),
            evidence: [makeEvidence(id: "ev1", metricKey: "health.sleep", value: 7, unit: "小时", sourceModule: .health, confidence: 0.4)]
        )
        // causal 是强表达类型，证据置信度 0.4 < 0.7 应降级（但因为 displayText 没有因果词所以不会被因果检查拒绝）
        expect(result.verdict == .degraded || result.verdict == .rejected, "弱证据强表达应降级或拒绝，实际 \(result.verdict)")
    }

    private static func test相关性claim单域_降级() {
        let verifier = HoloClaimVerifierV2()
        // 两个 metricAssertion 分别引用各自的 evidence，但证据都是 health 域
        let claim = HoloAgentClaim(
            id: "corr1", type: "correlation", displayText: "睡眠和步数有并发关系",
            metricAssertions: [
                HoloMetricAssertion(metricKey: "health.sleep", value: 7, unit: "小时", comparison: nil, evidenceIDs: ["ev1"]),
                HoloMetricAssertion(metricKey: "health.steps", value: 8000, unit: "步", comparison: nil, evidenceIDs: ["ev2"])
            ],
            evidenceIDs: ["ev1", "ev2"], prohibitedInferences: [],
            confidence: 0.7
        )
        let result = verifier.verify(
            claim: claim,
            evidence: [
                makeEvidence(id: "ev1", metricKey: "health.sleep", value: 7, unit: "小时", sourceModule: .health),
                makeEvidence(id: "ev2", metricKey: "health.steps", value: 8000, unit: "步", sourceModule: .health)
            ]
        )
        // 两个证据都是 health 域，不满足独立域要求 → 降级
        expect(result.verdict == .degraded, "相关性单域应降级，实际 \(result.verdict)")
    }

    private static func test重复血缘_降级() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(evidenceIDs: ["ev1", "ev2"]),
            evidence: [
                makeEvidence(id: "ev1", dedupeKey: "same-key"),
                makeEvidence(id: "ev2", dedupeKey: "same-key")
            ]
        )
        expect(result.verdict == .degraded, "重复血缘应降级，实际 \(result.verdict)")
    }

    private static func test模型置信度过高_降级() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(confidence: 0.95),
            evidence: [makeEvidence(id: "ev1", confidence: 0.5)]
        )
        // 模型 0.95 >> 证据 0.5，差异 > 0.2 应触发 expressionStrength 降级
        let expressionCheck = result.dimensionResults[.expressionStrength]
        expect(expressionCheck?.passed == false, "模型置信度过高应触发 expressionStrength 检查失败")
    }

    private static func test系统置信度计算_不受模型影响() {
        let verifier = HoloClaimVerifierV2()
        // 同样的证据，模型填不同 confidence，系统置信度应一致
        let r1 = verifier.verify(
            claim: makeClaim(confidence: 0.3),
            evidence: [makeEvidence(id: "ev1", confidence: 0.9)]
        )
        let r2 = verifier.verify(
            claim: makeClaim(confidence: 0.99),
            evidence: [makeEvidence(id: "ev1", confidence: 0.9)]
        )
        // 系统 confidence 主要由证据决定；模型 confidence 高会触发 expressionStrength 降级
        // 但系统 confidence 的基础部分（0.7 权重）不受模型 confidence 影响
        expect(abs(r1.systemConfidence - r2.systemConfidence) < 0.3, "系统置信度不应大幅受模型 confidence 影响")
    }

    private static func test降级文案含披露() {
        let verifier = HoloClaimVerifierV2()
        let result = verifier.verify(
            claim: makeClaim(value: 3000, unit: "美元"),
            evidence: [makeEvidence(id: "ev1", value: 3000, unit: "元")]
        )
        expect(result.degradedExpression != nil, "降级应有文案")
        expect(result.degradedExpression?.contains("注意") == true, "降级文案应含注意事项")
    }

    private static func test三态输出完整性() {
        let verifier = HoloClaimVerifierV2()
        // verified
        let v = verifier.verify(claim: makeClaim(), evidence: [makeEvidence(id: "ev1")])
        expect(v.verdict == .verified, "应 verified")
        // rejected
        let r = verifier.verify(claim: makeClaim(evidenceIDs: []), evidence: [])
        expect(r.verdict == .rejected, "应 rejected")
        // degraded
        let d = verifier.verify(claim: makeClaim(value: 3000, unit: "美元"), evidence: [makeEvidence(id: "ev1", value: 3000, unit: "元")])
        expect(d.verdict == .degraded, "应 degraded")
        expect(v.verdict != r.verdict && r.verdict != d.verdict, "三态应互不相同")
    }
}
