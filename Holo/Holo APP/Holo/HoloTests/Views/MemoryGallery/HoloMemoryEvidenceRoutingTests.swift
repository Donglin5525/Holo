import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryEvidenceRoutingTests.main()
    }
}
#endif
struct HoloMemoryEvidenceRoutingTests {
    private static var assertions = 0

    static func main() async throws {
        testEntityRefEvidenceRoutesToSourceDetail()
        testThoughtExplicitStatementRoutesToThoughtDetail()
        testConversationExplicitStatementStaysInPreviewSheet()
        testInvalidSourceIDHasNoRoute()
        try await testSourceLookupSkipsWhenSummaryExists()
        try await testSourceLookupMissingRecordReturnsNil()
        print("HoloMemoryEvidenceRoutingTests: \(assertions) assertions passed")
    }

    private static func makeEvidence(
        kind: HoloMemoryEvidenceKind,
        domain: HoloMemoryDomain,
        sourceID: String?
    ) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "evidence-\(kind.rawValue)-\(domain.rawValue)",
            kind: kind,
            sourceDomain: domain,
            lineageKey: "test:\(domain.rawValue)",
            sourceID: sourceID,
            revisionDigest: "r1",
            observedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private static func testEntityRefEvidenceRoutesToSourceDetail() {
        let financeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let finance = makeEvidence(kind: .entityRef, domain: .finance, sourceID: financeID.uuidString)
        guard case .transactionDetail(let transactionId)? = HoloMemoryEvidenceRouter.deepLinkTarget(for: finance) else {
            fatalError("财务 entityRef 证据应直达交易详情")
        }
        expect(transactionId == financeID, "路由必须携带原始交易 ID")
        expect(HoloMemoryEvidenceRouter.sourceEntityName(for: finance) == "Transaction",
               "财务证据应按 Transaction 实体校验存活")

        let goalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let goal = makeEvidence(kind: .entityRef, domain: .goal, sourceID: goalID.uuidString)
        guard case .goalDetail(let routedGoalID)? = HoloMemoryEvidenceRouter.deepLinkTarget(for: goal) else {
            fatalError("目标 entityRef 证据应直达目标详情")
        }
        expect(routedGoalID == goalID, "路由必须携带原始目标 ID")
    }

    private static func testThoughtExplicitStatementRoutesToThoughtDetail() {
        let thoughtID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let evidence = makeEvidence(
            kind: .explicitUserStatement, domain: .thought, sourceID: thoughtID.uuidString
        )
        guard case .thoughtDetail(let routedID)? = HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence) else {
            fatalError("观点域用户原话证据应直达原始想法详情")
        }
        expect(routedID == thoughtID, "路由必须携带原始想法 ID")
        expect(HoloMemoryEvidenceRouter.sourceEntityName(for: evidence) == "Thought",
               "观点域用户原话证据应按 Thought 实体校验存活")
    }

    private static func testConversationExplicitStatementStaysInPreviewSheet() {
        let messageID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let evidence = makeEvidence(
            kind: .explicitUserStatement, domain: .conversation, sourceID: messageID.uuidString
        )
        expect(HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence) == nil,
               "对话消息没有详情页路由，应由出处弹层回查原文展示")
        expect(HoloMemoryEvidenceRouter.sourceEntityName(for: evidence) == nil,
               "无路由证据不应参与原始记录存活校验")
    }

    private static func testInvalidSourceIDHasNoRoute() {
        let evidence = makeEvidence(
            kind: .explicitUserStatement, domain: .thought, sourceID: "not-a-uuid"
        )
        expect(HoloMemoryEvidenceRouter.deepLinkTarget(for: evidence) == nil,
               "sourceID 不是 UUID 时不得路由")
        let missingSource = makeEvidence(kind: .entityRef, domain: .finance, sourceID: nil)
        expect(HoloMemoryEvidenceRouter.deepLinkTarget(for: missingSource) == nil,
               "sourceID 缺失时不得路由")
    }

    private static func testSourceLookupSkipsWhenSummaryExists() async throws {
        let messageID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let withSummary = makeEvidence(
            kind: .explicitUserStatement, domain: .conversation, sourceID: messageID.uuidString
        )
        // 修改副本让 summary 已存在：回查必须直接跳过，不触库。
        var existing = withSummary
        existing.summary = "已保存的摘要"
        let result = await HoloMemoryEvidenceSourceLookup.liveText(for: existing)
        expect(result == nil, "已带摘要的证据不应触发回查")

        let noSource = makeEvidence(
            kind: .explicitUserStatement, domain: .thought, sourceID: nil
        )
        let missingSourceResult = await HoloMemoryEvidenceSourceLookup.liveText(for: noSource)
        expect(missingSourceResult == nil, "sourceID 缺失的证据无从回查")
    }

    /// 六域回查泛化后的兜底契约：库中不存在的记录（含带域前缀的 sourceKey 与
    /// thought 存量裸 UUID）一律返回 nil，由出处页落「已删除」占位。
    private static func testSourceLookupMissingRecordReturnsNil() async throws {
        let missingID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        for sourceID in [
            HoloLifeSourceKeys.conversationKey(missingID),
            HoloLifeSourceKeys.habitCheckinKey(missingID),
            HoloLifeSourceKeys.taskKey(missingID),
            HoloLifeSourceKeys.financeKey(missingID),
            HoloLifeSourceKeys.goalKey(missingID),
            missingID.uuidString,
        ] {
            let evidence = makeEvidence(
                kind: .explicitUserStatement, domain: .thought, sourceID: sourceID
            )
            let result = await HoloMemoryEvidenceSourceLookup.liveText(for: evidence)
            expect(result == nil, "库中不存在的来源（\(sourceID)）应返回 nil 而非编造文本")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }
}
