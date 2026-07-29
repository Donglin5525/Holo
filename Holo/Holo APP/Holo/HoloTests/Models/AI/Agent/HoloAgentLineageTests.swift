//
//  HoloAgentLineageTests.swift
//  HoloTests
//
//  连续追问 lineage 契约验证：
//  - root / parent 传播
//  - depth 递增 + 上限
//  - 防环
//  - 旧 JSON（无 lineage 字段）向后兼容
//  - relation 闭集 known-or-unknown 容错
//

import Foundation

@main
struct HoloAgentLineageTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testRootLineage_NilParent_Depth0()
        testChildLineage_LegacyParent_PicksUpRootAndDepth()
        testChildLineage_PropagatesRootAcrossDepth()
        testDepthLimit_TriggersRollingRoot()
        testCycleDetection_ChildEqualsParent()
        testCycleDetection_ChildEqualsRoot()
        testLegacyJSON_NoLineageField_DecodesAsNil()
        testUnknownRelationRawValue_FallsBackToAmbiguous()
        testContinuationDraft_MakesChildLineage()
        testLineage_CodableRoundTrip()
        print("HoloAgentLineageTests passed")
    }

    // MARK: - Helpers

    /// iso8601 round-trip（与 Store 编解码策略一致）
    private static func roundTrip<T: Codable & Equatable>(_ value: T) -> T? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// 构造一份 root lineage（模拟 root job 自描述，虽然 root 通常 lineage=nil）。
    private static func makeRootLineage(jobID: String, resultID: String) -> HoloAgentLineage {
        HoloAgentLineage(
            rootJobID: jobID,
            rootResultID: resultID,
            parentJobID: jobID,
            parentResultID: resultID,
            relationRawValue: HoloAgentFollowUpRelation.newTopic.rawValue,
            lineageDepth: 0
        )
    }

    // MARK: - Depth & Propagation

    /// 从 nil parent 构造 child：parent 升为 root，depth = 1。
    private static func testRootLineage_NilParent_Depth0() {
        let lineage = HoloAgentLineage(
            parentJobID: "job-root",
            parentResultID: "result-root",
            relation: .explain,
            parentLineage: nil
        )
        expect(lineage.rootJobID == "job-root", "nil parent 时 rootJobID 应为 parent")
        expect(lineage.rootResultID == "result-root", "nil parent 时 rootResultID 应为 parent")
        expect(lineage.parentJobID == "job-root", "parentJobID 应保留")
        expect(lineage.lineageDepth == 1, "nil parent 的 child depth 应为 1，实际 \(lineage.lineageDepth)")
        expect(lineage.relation == .explain, "relation 应为 explain")
    }

    /// legacy parent（无 lineage，即 parentLineage=nil）构造 child：root=parent, depth=1。
    /// 这是旧数据上第一次追问的场景。
    private static func testChildLineage_LegacyParent_PicksUpRootAndDepth() {
        let lineage = HoloAgentLineage(
            parentJobID: "job-legacy",
            parentResultID: "result-legacy",
            relation: .drillDown,
            parentLineage: nil
        )
        expect(lineage.rootJobID == "job-legacy", "legacy parent 的 child root 应为 parent")
        expect(lineage.lineageDepth == 1, "legacy parent child depth 应为 1")
    }

    /// 有 lineage 的 parent 构造 child：root 传播，depth +1。
    private static func testChildLineage_PropagatesRootAcrossDepth() {
        let root = makeRootLineage(jobID: "job-A", resultID: "result-A")
        let child1 = HoloAgentLineage(
            parentJobID: "job-A", parentResultID: "result-A",
            relation: .explain, parentLineage: root
        )
        expect(child1.rootJobID == "job-A", "child1 root 应传播为 job-A")
        expect(child1.lineageDepth == 1, "child1 depth 应为 1")

        let child2 = HoloAgentLineage(
            parentJobID: "job-B", parentResultID: "result-B",
            relation: .drillDown, parentLineage: child1
        )
        expect(child2.rootJobID == "job-A", "child2 root 应继续传播为 job-A")
        expect(child2.parentJobID == "job-B", "child2 直接 parent 应为 job-B")
        expect(child2.lineageDepth == 2, "child2 depth 应为 2")
    }

    /// depth 达上限时 needsRollingRoot 为 true。
    private static func testDepthLimit_TriggersRollingRoot() {
        let atLimit = HoloAgentLineage(
            rootJobID: "r", rootResultID: "r",
            parentJobID: "p", parentResultID: "p",
            relationRawValue: HoloAgentFollowUpRelation.explain.rawValue,
            lineageDepth: HoloAgentLineageLimit.maxDepth
        )
        expect(atLimit.needsRollingRoot, "达到 maxDepth 时应需要 rolling root")
        let belowLimit = HoloAgentLineage(
            rootJobID: "r", rootResultID: "r",
            parentJobID: "p", parentResultID: "p",
            relationRawValue: HoloAgentFollowUpRelation.explain.rawValue,
            lineageDepth: HoloAgentLineageLimit.maxDepth - 1
        )
        expect(!belowLimit.needsRollingRoot, "未达 maxDepth 时不应需要 rolling root")
    }

    // MARK: - Cycle Detection

    private static func testCycleDetection_ChildEqualsParent() {
        let lineage = makeRootLineage(jobID: "job-X", resultID: "result-X")
        expect(lineage.formsCycle(withChildJobID: "job-X"), "child jobID == parentJobID 应判环")
        expect(lineage.formsCycle(withChildJobID: "job-Y"), "child jobID == rootJobID 应判环")
        expect(!lineage.formsCycle(withChildJobID: "job-Z"), "无关 jobID 不应判环")
    }

    private static func testCycleDetection_ChildEqualsRoot() {
        // depth=2 的链：root=job-A，parent=job-B
        let root = makeRootLineage(jobID: "job-A", resultID: "r-A")
        let child = HoloAgentLineage(
            parentJobID: "job-B", parentResultID: "r-B",
            relation: .explain, parentLineage: root
        )
        expect(child.formsCycle(withChildJobID: "job-A"), "child jobID == rootJobID(job-A) 应判环")
        expect(child.formsCycle(withChildJobID: "job-B"), "child jobID == parentJobID(job-B) 应判环")
        expect(!child.formsCycle(withChildJobID: "job-C"), "新 jobID 不应判环")
    }

    // MARK: - Backward Compatibility

    /// 旧 Job JSON 没有 lineage 字段，解码后 lineage 应为 nil（optional 默认值）。
    private static func testLegacyJSON_NoLineageField_DecodesAsNil() {
        // 模拟旧 JSON：只有早期字段，无 lineage/originalUserQuestion
        let legacyJSON = """
        {
            "id": "job-old",
            "type": "deepAnalysis",
            "userQuestion": "本周睡眠",
            "trigger": "userQuestion",
            "state": "completed",
            "currentStep": "persistResult",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "budget": {
                "maxLLMRounds": 12, "maxToolBatches": 12,
                "maxInputTokens": 80000, "maxOutputTokens": 12000,
                "maxWallTimeSeconds": 300,
                "consumedLLMRounds": 1, "consumedToolBatches": 1,
                "consumedInputTokens": 100, "consumedOutputTokens": 100,
                "startedAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z"
            }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let job = try? decoder.decode(HoloAgentJob.self, from: Data(legacyJSON.utf8)) else {
            fatalError("旧 Job JSON 应可解码")
        }
        expect(job.lineage == nil, "旧 Job 解码后 lineage 应为 nil")
        expect(job.originalUserQuestion == nil, "旧 Job 解码后 originalUserQuestion 应为 nil")
        expect(job.userQuestion == "本周睡眠", "旧 Job userQuestion 应保留")
    }

    /// relationRawValue 是未知字符串时，relation 回落为 .ambiguous（known-or-unknown 容错）。
    private static func testUnknownRelationRawValue_FallsBackToAmbiguous() {
        let lineage = HoloAgentLineage(
            rootJobID: "r", rootResultID: "r",
            parentJobID: "p", parentResultID: "p",
            relationRawValue: "someFutureRelationV2",
            lineageDepth: 1
        )
        expect(lineage.relation == .ambiguous, "未知 relationRawValue 应回落为 ambiguous")
    }

    // MARK: - ContinuationDraft

    private static func testContinuationDraft_MakesChildLineage() {
        let parentLineage = makeRootLineage(jobID: "job-P", resultID: "result-P")
        let draft = HoloAgentContinuationDraft(
            parentResultID: "result-P",
            parentJobID: "job-P",
            parentLineage: parentLineage,
            rootUserQuestion: "本周睡眠怎么样",
            relation: .explain
        )
        let child = draft.makeChildLineage()
        expect(child.parentJobID == "job-P", "draft 构造的 child parentJobID 应为 draft.parentJobID")
        expect(child.parentResultID == "result-P", "child parentResultID 应正确")
        expect(child.rootJobID == "job-P", "child root 应从 parentLineage 传播")
        expect(child.lineageDepth == 1, "child depth 应为 parent depth + 1 = 1")
        expect(child.relation == .explain, "child relation 应为 draft.relation")
    }

    // MARK: - Codable

    private static func testLineage_CodableRoundTrip() {
        let original = HoloAgentLineage(
            rootJobID: "root-job", rootResultID: "root-result",
            parentJobID: "parent-job", parentResultID: "parent-result",
            relationRawValue: HoloAgentFollowUpRelation.changeScope.rawValue,
            lineageDepth: 5
        )
        guard let restored = roundTrip(original) else {
            fatalError("lineage Codable round-trip 失败")
        }
        expect(restored == original, "round-trip 后 lineage 应相等")
        expect(restored.relation == .changeScope, "round-trip 后 relation 应为 changeScope")
    }
}
