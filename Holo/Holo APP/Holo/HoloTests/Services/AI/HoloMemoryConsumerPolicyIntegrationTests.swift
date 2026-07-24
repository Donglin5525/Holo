import Foundation

actor HoloMemoryConsumerQueryStore: HoloMemoryQueryStore {
    let records: [HoloMemoryRecord]
    let suppressionSecret = "FORGOTTEN_SECRET_DO_NOT_EXPOSE"
    private(set) var fetchCount = 0

    init(records: [HoloMemoryRecord]) {
        self.records = records
    }

    func fetchAvailableMemoryRecords() async throws -> [HoloMemoryRecord] {
        fetchCount += 1
        return records
    }

    func fetchSuppressionCount() async throws -> Int { 1 }
    func currentFetchCount() -> Int { fetchCount }
}

struct HoloMemoryToolPolicySource: HoloMemoryDataSource {
    let records: [HoloMemoryToolRecord]
    let count: Int

    func queryRecords(question: String, currentStateOnly: Bool) async -> [HoloMemoryToolRecord] {
        records.filter { !currentStateOnly || $0.persistenceClass == .currentState }
    }

    func suppressionCount() async -> Int { count }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryConsumerPolicyIntegrationTests.main()
    }
}
#endif
struct HoloMemoryConsumerPolicyIntegrationTests {
    private static var assertions = 0

    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let active = try makeRecord(
            state: .active,
            summary: "近期更关注恢复节奏",
            evidenceSummary: "RAW_HEALTH_SECRET_DO_NOT_EXPOSE",
            now: now
        )
        let candidate = try makeRecord(
            state: .candidate,
            summary: "尚未达到可用门槛",
            evidenceSummary: "CANDIDATE_SECRET_DO_NOT_EXPOSE",
            now: now,
            anchorValue: "候选"
        )
        let store = HoloMemoryConsumerQueryStore(records: [active, candidate])

        for consumer in HoloMemoryAnswerConsumer.allCases {
            let deniedConsumer = consumer
            let deniedStore = HoloMemoryConsumerQueryStore(records: [active])
            let deniedService = HoloMemoryQueryService(
                store: deniedStore,
                answeringAllowed: { _ in false },
                refreshCoordinator: .init(handler: { _ in })
            )
            let denied = try await deniedService.query(
                question: "我最近状态如何",
                consumer: deniedConsumer,
                now: now
            )
            expect(denied.records.isEmpty, "关闭时 \(deniedConsumer.rawValue) 必须返回空记忆")
            expect(denied.refreshDecision == .disabled, "关闭时不得触发 SWR")
            let deniedFetchCount = await deniedStore.currentFetchCount()
            expect(deniedFetchCount == 0, "关闭时不得读取仓库")
        }

        let service = HoloMemoryQueryService(
            store: store,
            answeringAllowed: { _ in true },
            refreshCoordinator: .init(handler: { _ in })
        )
        let context = try await service.query(
            question: "我最近状态如何",
            consumer: .chat,
            now: now
        )
        expect(context.records.map(\.id) == [active.id], "只允许 active 记忆进入回答")

        let envelope = HoloMemoryContextEnvelope.render(context)
        expect(envelope.contains(active.aiUseSummary), "允许的摘要应进入模型上下文")
        expect(!envelope.contains("RAW_HEALTH_SECRET_DO_NOT_EXPOSE"), "底层 evidence 原文不得进入上下文")
        expect(!envelope.contains("CANDIDATE_SECRET_DO_NOT_EXPOSE"), "候选原文不得进入上下文")

        let trace = HoloMemorySelectionTrace(context: context)
        let traceData = try JSONEncoder().encode(trace)
        let traceJSON = String(decoding: traceData, as: UTF8.self)
        expect(traceJSON.contains(active.id), "trace 应包含选中的记忆 ID")
        expect(traceJSON.contains(context.route.rawValue), "trace 应包含路由")
        expect(!traceJSON.contains(active.aiUseSummary), "普通 trace 不得保存记忆正文")
        expect(!traceJSON.contains("RAW_HEALTH_SECRET_DO_NOT_EXPOSE"), "trace 不得保存 evidence 原文")

        let allowedSuppressionCount = await service.suppressionCount(consumer: .tool)
        expect(allowedSuppressionCount == 1, "Tool 可读取抑制状态计数")
        let deniedSuppression = HoloMemoryQueryService(
            store: store,
            answeringAllowed: { _ in false },
            refreshCoordinator: .init(handler: { _ in })
        )
        let deniedSuppressionCount = await deniedSuppression.suppressionCount(consumer: .tool)
        expect(deniedSuppressionCount == 0, "关闭记忆辅助后 suppression 计数也不可读取")

        let toolSource = HoloMemoryToolPolicySource(
            records: [HoloMemoryToolRecord(
                id: active.id,
                title: "健康记忆",
                summary: active.aiUseSummary,
                occurredAt: active.updatedAt,
                persistenceClass: active.persistenceClass
            )],
            count: 1
        )
        let tool = HoloMemoryTool(dataSource: toolSource)
        let suppressionResult = try await tool.execute(makeToolRequest("suppression_summary"))
        expect(suppressionResult.metrics.first?.value == 1, "Tool 应返回不可逆 suppression 计数")
        expect(suppressionResult.events.isEmpty, "Tool 不得返回 suppression 事件正文")
        let suppressionData = try JSONEncoder().encode(suppressionResult)
        let suppressionJSON = String(decoding: suppressionData, as: UTF8.self)
        expect(!suppressionJSON.contains("FORGOTTEN_SECRET_DO_NOT_EXPOSE"),
               "Tool 结果不得含忘记内容原文")

        print("HoloMemoryConsumerPolicyIntegrationTests: \(assertions) assertions passed")
    }

    private static func makeRecord(
        state: HoloMemoryState,
        summary: String,
        evidenceSummary: String,
        now: Date,
        anchorValue: String = "恢复状态"
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .healthMetric, value: anchorValue)
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(anchor.canonicalValue)",
            kind: .aggregateSnapshot,
            sourceDomain: .health,
            lineageKey: "health-\(anchor.canonicalValue)",
            revisionDigest: "rev-1",
            observedAt: now,
            validFrom: now.addingTimeInterval(-14 * 86_400),
            validTo: now,
            aggregateDefinition: "integration-test",
            sampleCount: 14,
            summary: evidenceSummary
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .health,
            sourceDomains: [.health],
            claimKind: .phaseShift,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .health,
            sourceDomains: [.health],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .phaseShift,
            persistenceClass: .phase,
            displaySummary: summary,
            aiUseSummary: summary,
            prohibitedInferences: ["medicalDiagnosis"],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: now.addingTimeInterval(-14 * 86_400),
            validTo: now,
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 0.9,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: .sensitive,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func makeToolRequest(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "memory-policy",
            tool: "memory",
            query: query,
            timeRange: nil,
            baseline: nil,
            requiredMetrics: [],
            parameters: [:]
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
