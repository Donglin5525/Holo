//
//  HoloAgentResultAvailabilityTests.swift
//  HoloTests
//
//  连续追问 Phase 5：结果有效性检查验证。
//

import Foundation

@main
struct HoloAgentResultAvailabilityTests {

    static func expect(_ c: @autoclosure () -> Bool, _ m: String) { if !c() { fatalError(m) } }

    static func main() {
        testNoEvidence_AlwaysAvailable()
        testAllEvidenceActive_Available()
        testAllEvidenceArchived_ReanalyzeRequired()
        testMajorityEvidenceOrphaned_TemporarilyUnavailable()
        testHalfActive_Available()
        testCanFollowUp_OnlyAvailable()
        testUserFacingHint_NonNilForNonAvailable()
        print("HoloAgentResultAvailabilityTests passed")
    }

    // MARK: - Helpers

    static func makeEvidence(id: String, status: HoloEvidenceStatus) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: "dk-\(id)", sourceModule: .health, sourceID: nil,
            sourceKind: "test", timeRange: nil, occurredAt: nil,
            metricKey: "health.steps.total", metricValue: 100, unit: "步",
            baselineValue: nil, baselineTimeRange: nil, comparison: nil,
            formula: nil, sourceRecordIDs: nil, semantic: nil,
            excerpt: "测试", redactedExcerpt: "测试",
            sensitivity: .normal, confidence: 0.9, status: status,
            generatedBy: "test", generatedAt: Date(),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    // MARK: - Tests

    static func testNoEvidence_AlwaysAvailable() {
        let result = HoloAgentResult(
            id: "r", jobID: "j", title: "测试", summary: "",
            claims: [], evidenceIDs: [], memoryCandidateIDs: [],
            status: "completed", generatedAt: Date(), updatedAt: Date()
        )
        let availability = HoloAgentResultAvailabilityChecker.check(result: result, availableEvidence: [])
        if case .available = availability {} else { fatalError("无 evidence 应 available") }
    }

    static func testAllEvidenceActive_Available() {
        let result = HoloAgentResult(
            id: "r", jobID: "j", title: "测试", summary: "",
            claims: [], evidenceIDs: ["e1", "e2"], memoryCandidateIDs: [],
            status: "completed", generatedAt: Date(), updatedAt: Date()
        )
        let evidence = [makeEvidence(id: "e1", status: .active), makeEvidence(id: "e2", status: .partial)]
        let availability = HoloAgentResultAvailabilityChecker.check(result: result, availableEvidence: evidence)
        if case .available = availability {} else { fatalError("全 active 应 available") }
    }

    static func testAllEvidenceArchived_ReanalyzeRequired() {
        let result = HoloAgentResult(
            id: "r", jobID: "j", title: "测试", summary: "",
            claims: [], evidenceIDs: ["e1", "e2"], memoryCandidateIDs: [],
            status: "completed", generatedAt: Date(), updatedAt: Date()
        )
        let evidence = [makeEvidence(id: "e1", status: .archived), makeEvidence(id: "e2", status: .orphaned)]
        let availability = HoloAgentResultAvailabilityChecker.check(result: result, availableEvidence: evidence)
        if case .reanalyzeRequired = availability {} else { fatalError("全失效应 reanalyzeRequired") }
    }

    static func testMajorityEvidenceOrphaned_TemporarilyUnavailable() {
        // 3 条 evidence，1 条 active，2 条 orphaned → active 占比 33% < 50% → temporarilyUnavailable
        let result = HoloAgentResult(
            id: "r", jobID: "j", title: "测试", summary: "",
            claims: [], evidenceIDs: ["e1", "e2", "e3"], memoryCandidateIDs: [],
            status: "completed", generatedAt: Date(), updatedAt: Date()
        )
        let evidence = [
            makeEvidence(id: "e1", status: .active),
            makeEvidence(id: "e2", status: .orphaned),
            makeEvidence(id: "e3", status: .orphaned)
        ]
        let availability = HoloAgentResultAvailabilityChecker.check(result: result, availableEvidence: evidence)
        if case .temporarilyUnavailable = availability {} else { fatalError("多数失效应 temporarilyUnavailable") }
    }

    static func testHalfActive_Available() {
        // 2 条 evidence，1 active 1 orphaned → active 占比 50%，不 < 50% → available
        let result = HoloAgentResult(
            id: "r", jobID: "j", title: "测试", summary: "",
            claims: [], evidenceIDs: ["e1", "e2"], memoryCandidateIDs: [],
            status: "completed", generatedAt: Date(), updatedAt: Date()
        )
        let evidence = [makeEvidence(id: "e1", status: .active), makeEvidence(id: "e2", status: .orphaned)]
        let availability = HoloAgentResultAvailabilityChecker.check(result: result, availableEvidence: evidence)
        if case .available = availability {} else { fatalError("半数 active 应 available") }
    }

    static func testCanFollowUp_OnlyAvailable() {
        expect(HoloAgentResultAvailability.available.canFollowUp, "available 可追问")
        expect(!HoloAgentResultAvailability.checking.canFollowUp, "checking 不可追问")
        expect(!HoloAgentResultAvailability.reanalyzeRequired(reason: "test").canFollowUp, "reanalyze 不可追问")
        expect(!HoloAgentResultAvailability.temporarilyUnavailable(reason: "test").canFollowUp, "tempUnavailable 不可追问")
    }

    static func testUserFacingHint_NonNilForNonAvailable() {
        expect(HoloAgentResultAvailability.available.userFacingHint == nil, "available 无提示")
        expect(HoloAgentResultAvailability.checking.userFacingHint != nil, "checking 有提示")
        expect(HoloAgentResultAvailability.reanalyzeRequired(reason: "").userFacingHint != nil, "reanalyze 有提示")
    }
}
