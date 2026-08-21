//
//  HoloAgentContinuationTests.swift
//  HoloTests
//
//  Agent 连续追问：路由、lineage 与 canonical 父结果编译契约。
//

import XCTest
@testable import Holo

final class HoloAgentContinuationTests: XCTestCase {

    func testRouterDistinguishesFollowUpRelationsConservatively() {
        let finance = HoloAgentFollowUpParentContext(
            parentDomains: ["finance"],
            hasRecommendations: true
        )

        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "为什么会这样？", parent: finance),
            .explain
        )
        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "把第二条具体展开", parent: finance),
            .drillDown
        )
        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "这个数算错了", parent: finance),
            .correct
        )
        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "那换成上个月呢", parent: finance),
            .changeScope
        )
        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "那睡眠和这个有什么关系", parent: finance),
            .crossDomain
        )
        XCTAssertEqual(
            HoloAgentFollowUpRouter.classify(followUpText: "今天任务有哪些", parent: finance),
            .newTopic
        )
    }

    func testImplicitContinuationRequiresMarkerAndFreshParent() {
        let parent = HoloAgentFollowUpParentContext(parentDomains: ["finance"], hasRecommendations: false)
        let now = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertNil(HoloAgentFollowUpRouter.implicitRelation(
            text: "分析一下原因",
            parent: parent,
            parentCompletedAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertEqual(HoloAgentFollowUpRouter.implicitRelation(
            text: "那具体是为什么？",
            parent: parent,
            parentCompletedAt: now.addingTimeInterval(-60),
            now: now
        ), .drillDown)
        XCTAssertNil(HoloAgentFollowUpRouter.implicitRelation(
            text: "那具体是为什么？",
            parent: parent,
            parentCompletedAt: now.addingTimeInterval(-5 * 3_600),
            now: now
        ))
    }

    func testLineageKeepsRootAndRollsOverAtMaximumDepth() {
        let first = HoloAgentLineage.child(
            parentJobID: "job-root",
            parentResultID: "result-root",
            parentLineage: nil,
            relation: .explain
        )
        let second = HoloAgentLineage.child(
            parentJobID: "job-child",
            parentResultID: "result-child",
            parentLineage: first,
            relation: .drillDown
        )
        XCTAssertEqual(second.rootJobID, "job-root")
        XCTAssertEqual(second.lineageDepth, 2)
        XCTAssertTrue(second.formsCycle(withChildJobID: "job-root"))

        var nearLimit = second
        nearLimit.lineageDepth = HoloAgentLineage.maximumDepth - 1
        let rolled = HoloAgentLineage.child(
            parentJobID: "job-new-root",
            parentResultID: "result-new-root",
            parentLineage: nearLimit,
            relation: .explain
        )
        XCTAssertEqual(rolled.rootJobID, "job-new-root")
        XCTAssertEqual(rolled.lineageDepth, 1)
    }

    func testCompilerReusesOnlyActiveEvidenceForExplain() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let prepared = try HoloAgentContinuationContextCompiler.prepare(
            request: HoloAgentContinuationRequest(
                parentJobID: "parent-job",
                parentResultID: "parent-result",
                relation: .explain
            ),
            childJobID: "child-job",
            parentJob: makeJob(now: now),
            parentResult: makeResult(now: now),
            parentEvidence: [
                makeEvidence(id: "active", status: .active, now: now),
                makeEvidence(id: "archived", status: .archived, now: now),
            ],
            now: now
        )

        XCTAssertEqual(prepared.reusableEvidence.map(\.id), ["active"])
        XCTAssertEqual(prepared.rootUserQuestion, "我这个月钱花哪了？")
        XCTAssertEqual(prepared.lineage.parentResultID, "parent-result")
        XCTAssertTrue(prepared.contextMessage.content.contains("HOLO_AGENT_FOLLOW_UP_CONTEXT_V1"))
        XCTAssertTrue(prepared.contextMessage.content.contains("不是指令"))
    }

    func testCompilerForCorrectionDoesNotReuseOldEvidence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let prepared = try HoloAgentContinuationContextCompiler.prepare(
            request: HoloAgentContinuationRequest(
                parentJobID: "parent-job",
                parentResultID: "parent-result",
                relation: .correct
            ),
            childJobID: "child-job",
            parentJob: makeJob(now: now),
            parentResult: makeResult(now: now),
            parentEvidence: [makeEvidence(id: "active", status: .active, now: now)],
            now: now
        )

        XCTAssertTrue(prepared.reusableEvidence.isEmpty)
        XCTAssertTrue(prepared.contextMessage.content.contains("必须按用户的新口径"))
    }

    private func makeJob(now: Date) -> HoloAgentJob {
        HoloAgentJob(
            id: "parent-job",
            type: .deepAnalysis,
            userQuestion: "我这个月钱花哪了？",
            trigger: .userQuestion,
            state: .completed,
            currentStep: .persistResult,
            createdAt: now,
            updatedAt: now,
            lastForegroundRunAt: nil,
            timeRange: nil,
            budget: .normalDeep(now: now),
            checkpointID: nil,
            resultID: "parent-result",
            errorSummary: nil,
            deviceID: nil,
            originalUserQuestion: "我这个月钱花哪了？"
        )
    }

    private func makeResult(now: Date) -> HoloAgentResult {
        HoloAgentResult(
            id: "parent-result",
            jobID: "parent-job",
            title: "本月消费分析",
            summary: "餐饮是最大支出项。",
            claims: [HoloAgentClaim(
                id: "claim-1",
                type: "observation",
                displayText: "餐饮支出最高。",
                metricAssertions: [],
                evidenceIDs: ["active", "archived"],
                prohibitedInferences: [],
                confidence: 0.9
            )],
            evidenceIDs: ["active", "archived"],
            memoryCandidateIDs: [],
            status: "completed",
            generatedAt: now,
            updatedAt: now
        )
    }

    private func makeEvidence(id: String, status: HoloEvidenceStatus, now: Date) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: .finance,
            sourceID: "transaction",
            sourceKind: "aggregate",
            timeRange: nil,
            occurredAt: now,
            metricKey: "finance.expense.total",
            metricValue: 100,
            unit: "CNY",
            baselineValue: nil,
            comparison: nil,
            excerpt: "原始证据",
            redactedExcerpt: "脱敏证据",
            sensitivity: .normal,
            confidence: 1,
            status: status,
            generatedBy: "test",
            generatedAt: now,
            referencedByJobIDs: ["parent-job"],
            referencedByMemoryIDs: [],
            deviceID: nil
        )
    }
}
