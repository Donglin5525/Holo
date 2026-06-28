//
//  HealthInsightVerifierTests.swift
//  HoloTests
//
//  健康洞察质量门禁测试：evidence 命中、跨域、置信度、长度、禁词。
//

import XCTest
@testable import Holo

final class HealthInsightVerifierTests: XCTestCase {

    private let verifier = HealthInsightVerifier()

    private func evidence(_ id: String, _ domain: HealthInsightDomain) -> HealthInsightEvidence {
        HealthInsightEvidence(
            id: id, domain: domain, occurredAt: nil,
            title: id, detail: "", metricKey: nil, metricValue: nil, unit: nil
        )
    }

    private func makeInsight(
        kind: HealthInsightKind,
        domain: HealthInsightDomain,
        evidenceIds: [String],
        confidence: Double = 0.7,
        title: String = "正常洞察标题",
        summary: String = "这是一段正常的洞察摘要内容。",
        caveat: String? = nil
    ) -> GeneratedHealthInsight {
        GeneratedHealthInsight(
            id: "i", kind: kind, domain: domain, title: title, summary: summary,
            suggestedAction: nil, confidence: confidence, evidenceIds: evidenceIds, caveat: caveat
        )
    }

    func testCoreWithAtLeastOneValidEvidencePasses() {
        let ev = [evidence("health-sleep-20260622", .health)]
        let parsed = HealthInsightParsedInsights(
            coreInsight: makeInsight(kind: .core, domain: .health, evidenceIds: ["health-sleep-20260622"]),
            lifestyleLoops: []
        )
        XCTAssertNotNil(verifier.verify(parsed, evidence: ev).coreInsight)
    }

    func testCoreWithoutValidEvidenceDropped() {
        let ev = [evidence("health-sleep-20260622", .health)]
        let parsed = HealthInsightParsedInsights(
            coreInsight: makeInsight(kind: .core, domain: .health, evidenceIds: ["FAKE-ID"]),
            lifestyleLoops: []
        )
        XCTAssertNil(verifier.verify(parsed, evidence: ev).coreInsight)
    }

    func testLoopRequiresAtLeastTwoDistinctDomains() {
        // 审查修订 P5：判定 evidenceIds → evidence.domain 去重 ≥2，不是 loop.domain
        let ev = [
            evidence("health-sleep-20260622", .health),
            evidence("finance-keyword-coffee-20260622", .finance),
            evidence("health-sleep-20260623", .health)
        ]
        let crossDomain = makeInsight(
            kind: .lifestyleLoop, domain: .mixed,
            evidenceIds: ["health-sleep-20260622", "finance-keyword-coffee-20260622"]
        )
        let singleDomain = makeInsight(
            kind: .lifestyleLoop, domain: .health,
            evidenceIds: ["health-sleep-20260622", "health-sleep-20260623"]
        )
        let parsed = HealthInsightParsedInsights(coreInsight: nil, lifestyleLoops: [crossDomain, singleDomain])

        let result = verifier.verify(parsed, evidence: ev)
        XCTAssertEqual(result.lifestyleLoops.count, 1)  // 只剩跨域那条
    }

    func testLoopBelowConfidenceThresholdDropped() {
        let ev = [evidence("a", .health), evidence("b", .finance)]
        let parsed = HealthInsightParsedInsights(
            coreInsight: nil,
            lifestyleLoops: [makeInsight(kind: .lifestyleLoop, domain: .mixed, evidenceIds: ["a", "b"], confidence: 0.4)]
        )
        XCTAssertTrue(verifier.verify(parsed, evidence: ev).lifestyleLoops.isEmpty)
    }

    func testLoopWithTooFewValidEvidenceDropped() {
        let ev = [evidence("a", .health)]
        let parsed = HealthInsightParsedInsights(
            coreInsight: nil,
            lifestyleLoops: [makeInsight(kind: .lifestyleLoop, domain: .mixed, evidenceIds: ["a"])]
        )
        XCTAssertTrue(verifier.verify(parsed, evidence: ev).lifestyleLoops.isEmpty)
    }

    func testInsightWithBannedTermDropped() {
        let ev = [evidence("a", .health), evidence("b", .finance)]
        let withDiagnosis = makeInsight(
            kind: .lifestyleLoop, domain: .mixed, evidenceIds: ["a", "b"],
            title: "你可能有抑郁症", summary: "需要去医院治疗", caveat: nil
        )
        let parsed = HealthInsightParsedInsights(coreInsight: nil, lifestyleLoops: [withDiagnosis])
        XCTAssertTrue(verifier.verify(parsed, evidence: ev).lifestyleLoops.isEmpty)
    }

    func testLoopTitleTooLongDropped() {
        let ev = [evidence("a", .health), evidence("b", .finance)]
        let longTitle = String(repeating: "字", count: 25)  // > 24
        let parsed = HealthInsightParsedInsights(
            coreInsight: nil,
            lifestyleLoops: [makeInsight(kind: .lifestyleLoop, domain: .mixed, evidenceIds: ["a", "b"], title: longTitle)]
        )
        XCTAssertTrue(verifier.verify(parsed, evidence: ev).lifestyleLoops.isEmpty)
    }
}
