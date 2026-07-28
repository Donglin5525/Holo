//
//  HoloClaimVerifierTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 4.1 Claim Verifier 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Verification/HoloClaimVerifier.swift> <本测试> \
//    -o /tmp/holo_claim_verifier_test && /tmp/holo_claim_verifier_test
//

import Foundation

@main
struct HoloClaimVerifierTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testEvidenceID不存在时rejected()
        testMetricKey不匹配时rejected()
        testValue不一致时rejected()
        test因果词时rejected()
        test没有证据的Claim必须rejected()
        test建议夹带无证据数字目标必须rejected()
        test事实文案夹带无证据数字必须rejected()
        test合法Claim被accepted()
        test重复EvidenceID不会崩溃()
        print("HoloClaimVerifierTests passed")
    }

    private static func makeEvidence(id: String, metricKey: String, metricValue: Double) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: .habit, sourceID: nil, sourceKind: "kind",
            timeRange: nil, occurredAt: nil, metricKey: metricKey, metricValue: metricValue, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: "原文", redactedExcerpt: "脱敏",
            sensitivity: .normal, confidence: 1.0, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 1000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func makeClaim(metricKey: String, value: Double?, evidenceIDs: [String],
                                  displayText: String = "观察到的变化") -> HoloAgentClaim {
        HoloAgentClaim(
            id: "c1", type: "observation", displayText: displayText,
            metricAssertions: [
                HoloMetricAssertion(metricKey: metricKey, value: value, baselineValue: nil,
                                    unit: "次", comparison: nil, evidenceIDs: evidenceIDs)
            ],
            evidenceIDs: evidenceIDs, prohibitedInferences: [], confidence: 0.9
        )
    }

    private static func testEvidenceID不存在时rejected() {
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12, evidenceIDs: ["ghost"])
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [])
        expect(result.acceptedClaims.isEmpty, "evidenceID 不存在应 rejected")
        expect(result.rejectedClaims.count == 1, "应有 1 条 rejected")
    }

    private static func testMetricKey不匹配时rejected() {
        let ev = makeEvidence(id: "e1", metricKey: "finance.amount.change", metricValue: 12)
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12, evidenceIDs: ["e1"])
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.isEmpty, "metricKey 不匹配应 rejected")
    }

    private static func testValue不一致时rejected() {
        let ev = makeEvidence(id: "e1", metricKey: "habit.negative.frequency_change", metricValue: 8)
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12, evidenceIDs: ["e1"])
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.isEmpty, "value 不一致应 rejected")
    }

    private static func test因果词时rejected() {
        let ev = makeEvidence(id: "e1", metricKey: "habit.negative.frequency_change", metricValue: 12)
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12,
                              evidenceIDs: ["e1"], displayText: "熬夜导致了开销增加")
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.isEmpty, "含因果词「导致」应 rejected")
    }

    private static func test没有证据的Claim必须rejected() {
        let claim = HoloAgentClaim(
            id: "c-empty",
            type: "observation",
            displayText: "系统目前无法获取对应的支出拆分数据",
            metricAssertions: [],
            evidenceIDs: [],
            prohibitedInferences: [],
            confidence: 0.5
        )
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [])
        expect(result.acceptedClaims.isEmpty, "没有 metricAssertions/evidenceIDs 的 claim 必须 rejected")
        expect(result.rejectedClaims.count == 1, "应记录 rejected 原因")
    }

    private static func test建议夹带无证据数字目标必须rejected() {
        let ev = makeEvidence(id: "e1", metricKey: "finance.category.dining.amount", metricValue: 25_800)
        let claim = HoloAgentClaim(
            id: "c-invented-budget",
            type: "suggestion",
            displayText: "建议把餐饮预算控制在每月1500元以内，预计节省600-1200元",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.category.dining.amount",
                    value: 25_800,
                    baselineValue: nil,
                    unit: "元",
                    comparison: nil,
                    evidenceIDs: ["e1"]
                )
            ],
            evidenceIDs: ["e1"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.isEmpty, "建议夹带无证据预算/节省数字必须 rejected")
    }

    private static func test事实文案夹带无证据数字必须rejected() {
        let ev = makeEvidence(id: "e1", metricKey: "finance.category.dining.amount", metricValue: 25_800)
        let claim = HoloAgentClaim(
            id: "c-invented-share",
            type: "observation",
            displayText: "餐饮支出25,800元，占总支出的50%",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.category.dining.amount",
                    value: 25_800,
                    baselineValue: nil,
                    unit: "元",
                    comparison: nil,
                    evidenceIDs: ["e1"]
                )
            ],
            evidenceIDs: ["e1"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.isEmpty, "事实正文夹带无法复算的占比必须 rejected")
    }

    private static func test合法Claim被accepted() {
        let ev = makeEvidence(id: "e1", metricKey: "habit.negative.frequency_change", metricValue: 12)
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12,
                              evidenceIDs: ["e1"], displayText: "负向习惯发生量上升")
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev])
        expect(result.acceptedClaims.count == 1, "合法 claim 应 accepted")
        expect(result.rejectedClaims.isEmpty, "不应有 rejected")
    }

    private static func test重复EvidenceID不会崩溃() {
        let ev1 = makeEvidence(id: "e1", metricKey: "habit.negative.frequency_change", metricValue: 12)
        let ev2 = makeEvidence(id: "e1", metricKey: "habit.negative.frequency_change", metricValue: 12)
        let claim = makeClaim(metricKey: "habit.negative.frequency_change", value: 12,
                              evidenceIDs: ["e1"], displayText: "负向习惯发生量上升")
        let result = HoloClaimVerifier().verify(claims: [claim], evidence: [ev1, ev2])
        expect(result.acceptedClaims.count == 1, "重复 evidence id 不应导致校验器崩溃")
    }
}
