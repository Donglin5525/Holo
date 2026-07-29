//
//  HoloAgentContextCompilerGuardTests.swift
//  HoloTests
//
//  连续追问 Phase 2：Context Compiler + Guard 验证。
//  运行：swiftc -parse-as-library <源码> <本测试> -o /tmp/holo_ctx_tests && /tmp/holo_ctx_tests
//

import Foundation

@main
struct HoloAgentContextCompilerGuardTests {

    static func expect(_ c: @autoclosure () -> Bool, _ m: String) { if !c() { fatalError(m) } }

    static func main() {
        testGuard_AuthorizesActiveEvidence()
        testGuard_RejectsOrphanedAndArchived()
        testGuard_ReportsMissingEvidence()
        testCompiler_DropsClaimsWithoutAuthorizedEvidence()
        testCompiler_KeepsClaimsWithPartialAuthorizedEvidence()
        testCompiler_EmptySnapshotProducesEmptyBlock()
        testCompiler_DataBlockIsolationMarkers()
        testCompiler_ScopeAndDigestIncluded()
        print("HoloAgentContextCompilerGuardTests passed")
    }

    // MARK: - Helpers

    /// 构造一条最小可用 evidence（测试夹具，字段尽量精简）。
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

    static func makeSnapshot(
        claims: [(id: String, text: String, evidenceIDs: [String])],
        evidenceIDs: [String],
        digest: String? = "父分析摘要"
    ) -> HoloAgentFollowUpContextSnapshot {
        let digests = claims.map { c in
            HoloAgentFollowUpContextSnapshot.ClaimDigest(
                claimID: c.id, displayText: c.text, evidenceIDs: c.evidenceIDs, claimType: "observation"
            )
        }
        return HoloAgentFollowUpContextSnapshot(
            parentResultID: "r", parentJobID: "j",
            inheritedClaimDigests: digests,
            inheritedEvidenceIDs: evidenceIDs,
            parentScopeLabel: "本周", parentSnapshotCutoffAt: Date(),
            digest: digest
        )
    }

    // MARK: - Guard

    /// active / partial evidence 通过授权。
    static func testGuard_AuthorizesActiveEvidence() {
        let snapshot = makeSnapshot(claims: [], evidenceIDs: ["e1", "e2"])
        let available = [makeEvidence(id: "e1", status: .active), makeEvidence(id: "e2", status: .partial)]
        let result = HoloAgentContextGuard.authorize(snapshot: snapshot, availableEvidence: available)
        expect(result.authorizedEvidenceIDs == ["e1", "e2"], "active+partial 应全部授权")
        expect(result.rejectedEvidence.isEmpty, "不应有拒绝")
        expect(result.missingEvidenceIDs.isEmpty, "不应有缺失")
    }

    /// orphaned / archived evidence 被拒绝。
    static func testGuard_RejectsOrphanedAndArchived() {
        let snapshot = makeSnapshot(claims: [], evidenceIDs: ["e1", "e2"])
        let available = [makeEvidence(id: "e1", status: .orphaned), makeEvidence(id: "e2", status: .archived)]
        let result = HoloAgentContextGuard.authorize(snapshot: snapshot, availableEvidence: available)
        expect(result.authorizedEvidenceIDs.isEmpty, "orphaned+archived 不应授权")
        expect(result.rejectedEvidence["e1"] == "orphaned", "e1 应标记 orphaned")
        expect(result.rejectedEvidence["e2"] == "archived", "e2 应标记 archived")
    }

    /// ledger 里找不到的 evidence 报为 missing。
    static func testGuard_ReportsMissingEvidence() {
        let snapshot = makeSnapshot(claims: [], evidenceIDs: ["e1", "e9"])
        let available = [makeEvidence(id: "e1", status: .active)]
        let result = HoloAgentContextGuard.authorize(snapshot: snapshot, availableEvidence: available)
        expect(result.authorizedEvidenceIDs == ["e1"], "只有 e1 授权")
        expect(result.missingEvidenceIDs == ["e9"], "e9 应报缺失")
    }

    // MARK: - Compiler

    /// claim 引用的 evidence 全部失效 → 该 claim 被丢弃。
    static func testCompiler_DropsClaimsWithoutAuthorizedEvidence() {
        let snapshot = makeSnapshot(
            claims: [("c1", "结论1", ["e1"]), ("c2", "结论2", ["e9"])],
            evidenceIDs: ["e1", "e9"]
        )
        // e9 不在 available → 被 guard 判 missing → c2 的 evidence 全失效 → 丢弃
        let available = [makeEvidence(id: "e1", status: .active)]
        let guardResult = HoloAgentContextGuard.authorize(snapshot: snapshot, availableEvidence: available)
        let compiled = HoloAgentContextCompiler.compile(
            snapshot: snapshot, authorizedEvidenceIDs: guardResult.authorizedEvidenceIDs
        )
        expect(compiled.droppedClaimCount == 1, "应丢弃 1 个 claim，实际 \(compiled.droppedClaimCount)")
        expect(compiled.dataBlock.contains("结论1"), "保留的 c1 正文应在 block 中")
        expect(!compiled.dataBlock.contains("结论2"), "丢弃的 c2 正文不应在 block 中")
    }

    /// claim 只要有一条 evidence 仍有效就保留。
    static func testCompiler_KeepsClaimsWithPartialAuthorizedEvidence() {
        let snapshot = makeSnapshot(
            claims: [("c1", "结论1", ["e1", "e9"])],
            evidenceIDs: ["e1", "e9"]
        )
        let available = [makeEvidence(id: "e1", status: .active)]
        let guardResult = HoloAgentContextGuard.authorize(snapshot: snapshot, availableEvidence: available)
        let compiled = HoloAgentContextCompiler.compile(
            snapshot: snapshot, authorizedEvidenceIDs: guardResult.authorizedEvidenceIDs
        )
        expect(compiled.droppedClaimCount == 0, "c1 有 e1 有效，不应丢弃")
        expect(compiled.dataBlock.contains("结论1"), "c1 正文应保留")
    }

    /// 空 claim + 无 digest → 不产出 block。
    static func testCompiler_EmptySnapshotProducesEmptyBlock() {
        let snapshot = makeSnapshot(claims: [], evidenceIDs: [], digest: nil)
        let compiled = HoloAgentContextCompiler.compile(
            snapshot: snapshot, authorizedEvidenceIDs: []
        )
        expect(!compiled.hasContent, "空快照不应产出 block")
        expect(compiled.dataBlock.isEmpty, "空快照 dataBlock 应为空")
    }

    /// data block 必须有起止隔离标记。
    static func testCompiler_DataBlockIsolationMarkers() {
        let snapshot = makeSnapshot(claims: [("c1", "结论1", ["e1"])], evidenceIDs: ["e1"])
        let compiled = HoloAgentContextCompiler.compile(
            snapshot: snapshot, authorizedEvidenceIDs: ["e1"]
        )
        expect(compiled.dataBlock.contains(HoloAgentContextCompiler.blockStart), "应有起始标记")
        expect(compiled.dataBlock.contains(HoloAgentContextCompiler.blockEnd), "应有结束标记")
        // 起始标记必须在结束标记之前
        let startRange = compiled.dataBlock.range(of: HoloAgentContextCompiler.blockStart)!
        let endRange = compiled.dataBlock.range(of: HoloAgentContextCompiler.blockEnd)!
        expect(startRange.lowerBound < endRange.lowerBound, "起始标记应在结束标记之前")
    }

    /// scope 和 digest 应出现在 block 中。
    static func testCompiler_ScopeAndDigestIncluded() {
        let snapshot = makeSnapshot(claims: [], evidenceIDs: ["e1"], digest: "这是父分析摘要")
        let compiled = HoloAgentContextCompiler.compile(
            snapshot: snapshot, authorizedEvidenceIDs: ["e1"]
        )
        expect(compiled.dataBlock.contains("本周"), "scope 标签应在 block 中")
        expect(compiled.dataBlock.contains("这是父分析摘要"), "digest 应在 block 中")
    }
}
