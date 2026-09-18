//
//  GoalWorkshopStoreTests.swift
//  HoloTests
//
//  目标共创会话/版本存储测试（方案任务 2）：
//  创建/读取/修改/放弃、App 重启恢复、旧 Goal 无版本、旧 payload 未知版本隔离、
//  CloudKit 副本同 id 去重、删除、并发旧 revision 不覆盖新 revision、幂等版本记录。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalWorkshopStoreTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var store: GoalWorkshopStore!
    private var revisionStore: GoalPlanRevisionStore!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["GoalWorkshopSessionMO", "GoalPlanRevisionMO"])
        store = GoalWorkshopStore(context: context)
        revisionStore = GoalPlanRevisionStore(context: context)
    }

    // MARK: - 工厂

    private func makeSession(seed: String = "我想在工作会议中更敢开口说英语",
                             phase: GoalWorkshopPhase = .understanding,
                             revision: Int = 0) -> GoalWorkshopSessionV1 {
        var session = GoalWorkshopSessionV1(originalText: seed)
        session.phase = phase
        session.revision = revision
        return session
    }

    private func makeSummary(planTitle: String = "工作会议英语敢开口") -> GoalWorkshopDecisionSummaryV1 {
        GoalWorkshopDecisionSummaryV1(
            definition: GoalWorkshopGoalDefinition(
                title: planTitle, desiredOutcome: "周会发言一次", motivation: nil, deadlineText: "2026-12-31"
            ),
            selectedRouteTitle: "先练会议听说",
            planTitle: planTitle,
            successEvidence: "连续四周周会发言",
            assumptions: ["假设每周有英文周会"],
            firstActionTitle: "准备英文自我介绍",
            selectedTaskTitles: ["准备英文自我介绍"],
            selectedHabitNames: ["跟读会议录音"],
            allowAIContext: true
        )
    }

    // MARK: - 会话存取

    func testCreateReadModifyRoundtrip() throws {
        var session = makeSession()
        try session.applyUserReply("每周三早上的周会")
        try store.saveIfRevisionMatches(session)

        let loaded = try store.load(id: session.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.phase, .understanding)
        XCTAssertEqual(loaded?.revision, 1)
        XCTAssertEqual(loaded?.facts.filter { $0.provenance == .userStated }.count, 1)
        XCTAssertEqual(loaded?.originalText, session.originalText)

        var updated = loaded!
        try updated.applyUserReply("主要是怕说错")
        try store.saveIfRevisionMatches(updated)
        let reloaded = try store.load(id: session.id)
        XCTAssertEqual(reloaded?.revision, 2)
        XCTAssertEqual(reloaded?.facts.filter { $0.provenance == .userStated }.count, 2)
    }

    func testRestartRecoveryViaNewStoreInstance() throws {
        // 模拟 App 重启：Store 是无状态包装，新建实例应读回同一会话
        var session = makeSession()
        session.routeOptions = [
            GoalRouteOption(id: "r1", title: "先练会议听说", fit: "x", effort: "x", tradeoff: "x", reason: "x")
        ]
        session.phase = .exploring
        session.revision = 5
        try store.saveIfRevisionMatches(session)

        let freshStore = GoalWorkshopStore(context: context)
        // iOS 26.3 模拟器 hosted XCTest 的系统级重复释放缓解（CoreDataTestSupport 既定政策）
        CoreDataTestSupport.retain(freshStore)
        let recovered = try freshStore.load(id: session.id)
        XCTAssertEqual(recovered?.phase, .exploring)
        XCTAssertEqual(recovered?.revision, 5)
        XCTAssertEqual(recovered?.routeOptions.first?.id, "r1")

        let resumable = try freshStore.listResumable()
        XCTAssertEqual(resumable.map(\.id), [session.id])
    }

    func testListResumableExcludesTerminalAndDeleted() throws {
        var active = makeSession(seed: "进行中会话")
        active.revision = 1
        try store.saveIfRevisionMatches(active)

        var saved = makeSession(seed: "已保存会话", phase: .saved, revision: 1)
        try store.saveIfRevisionMatches(saved)
        var abandoned = makeSession(seed: "已放弃会话", phase: .abandoned, revision: 1)
        try store.saveIfRevisionMatches(abandoned)

        let resumable = try store.listResumable()
        XCTAssertEqual(resumable.map(\.id), [active.id])
    }

    func testDiscardRemovesSession() throws {
        var session = makeSession()
        session.revision = 1
        try store.saveIfRevisionMatches(session)

        try store.discard(id: session.id)
        XCTAssertNil(try store.load(id: session.id))
        XCTAssertTrue(try store.listResumable().isEmpty)
    }

    // MARK: - 并发与去重

    func testStaleRevisionDoesNotOverwriteNewer() throws {
        var session = makeSession()
        session.revision = 1
        try store.saveIfRevisionMatches(session)

        // 旧 revision 重放（revision 相同）→ 拒绝
        var stale = session
        stale.originalText = "旧的写入"
        XCTAssertThrowsError(try store.saveIfRevisionMatches(stale)) { error in
            guard case GoalWorkshopStoreError.revisionConflict = error else {
                return XCTFail("应抛 revisionConflict：\(error)")
            }
        }
        // 更旧（0 < 1）→ 拒绝
        var older = session
        older.revision = 0
        XCTAssertThrowsError(try store.saveIfRevisionMatches(older))

        // 数据未被旧写入覆盖
        let current = try store.load(id: session.id)
        XCTAssertEqual(current?.originalText, session.originalText)

        // 更新（2 > 1）→ 接受
        var newer = session
        newer.revision = 2
        newer.originalText = "新的写入"
        try store.saveIfRevisionMatches(newer)
        XCTAssertEqual(try store.load(id: session.id)?.originalText, "新的写入")
    }

    func testExpectedRevisionMismatchRejected() throws {
        var session = makeSession()
        session.revision = 3
        try store.saveIfRevisionMatches(session)

        // 他方已把 stored 推到 3，调用方仍以为停在 1 → 拒绝并要求重读
        var attempt = session
        attempt.revision = 4
        XCTAssertThrowsError(try store.saveIfRevisionMatches(attempt, expectedRevision: 1)) { error in
            guard case GoalWorkshopStoreError.revisionConflict = error else {
                return XCTFail("应抛 revisionConflict：\(error)")
            }
        }
        try store.saveIfRevisionMatches(attempt, expectedRevision: 3)
        XCTAssertEqual(try store.load(id: session.id)?.revision, 4)
    }

    func testCloudKitDuplicateIDDeduplication() throws {
        var session = makeSession()
        session.revision = 2
        try store.saveIfRevisionMatches(session)

        // 人为制造 iCloud 副本：同 id 再插一行，updatedAt 更新
        let copy = GoalWorkshopSessionMO.make(in: context, payload: GoalWorkshopSessionPayload(session: session))
        copy.updatedAt = Date(timeIntervalSinceNow: 60)
        try context.save()

        let loaded = try store.load(id: session.id)
        XCTAssertNotNil(loaded)
        let resumable = try store.listResumable()
        XCTAssertEqual(resumable.filter { $0.id == session.id }.count, 1, "同 id 副本必须去重")
        _ = copy
    }

    // MARK: - payload 版本隔离

    func testUnknownPayloadVersionIsolated() throws {
        var session = makeSession()
        session.revision = 1
        try store.saveIfRevisionMatches(session)

        // 人为把该行 payload 升到未来版本（模拟更高版本 App 写入后回退安装）
        guard let mo = (try? context.fetch(NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")))?
            .first(where: { $0.id == session.id }) else {
            return XCTFail("会话行缺失")
        }
        let futurePayload = """
        {"schemaVersion":99,"session":{}}
        """
        mo.payloadJSON = futurePayload
        try context.save()

        // 读取被隔离（抛不兼容），但行数据不被清掉，其他会话不受影响
        XCTAssertThrowsError(try store.load(id: session.id)) { error in
            guard case GoalWorkshopStoreError.incompatiblePayload = error else {
                return XCTFail("应抛 incompatiblePayload：\(error)")
            }
        }
        XCTAssertEqual(mo.payloadJSON, futurePayload, "未知版本数据必须原样保留")

        var other = makeSession(seed: "另一个会话")
        other.revision = 1
        try store.saveIfRevisionMatches(other)
        XCTAssertNotNil(try store.load(id: other.id))
    }

    // MARK: - 决策版本

    func testRevisionRecordAndIdempotency() throws {
        let goalID = UUID()
        // 旧 Goal 无版本记录 → 空数组、版本号 0
        XCTAssertTrue(try revisionStore.loadRevisions(goalID: goalID).isEmpty)
        XCTAssertEqual(revisionStore.latestRevisionNumber(goalID: goalID), 0)

        try revisionStore.record(goalID: goalID, sourceSessionID: UUID(), revisionNumber: 1, summary: makeSummary())
        try revisionStore.record(goalID: goalID, sourceSessionID: UUID(), revisionNumber: 2, summary: makeSummary(planTitle: "调整后的计划"))

        let revisions = try revisionStore.loadRevisions(goalID: goalID)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(revisions[0].planTitle, "工作会议英语敢开口")
        XCTAssertEqual(revisions[1].planTitle, "调整后的计划")
        XCTAssertEqual(revisionStore.latestRevisionNumber(goalID: goalID), 2)

        // 同版本号重复写入 → 幂等，不新增
        try revisionStore.record(goalID: goalID, sourceSessionID: UUID(), revisionNumber: 2, summary: makeSummary())
        XCTAssertEqual(try revisionStore.loadRevisions(goalID: goalID).count, 2)
    }

    func testDecisionSummaryRoundtripKeepsContractFields() throws {
        let goalID = UUID()
        let summary = makeSummary()
        try revisionStore.record(goalID: goalID, sourceSessionID: UUID(), revisionNumber: 1, summary: summary)

        let loaded = try revisionStore.loadRevisions(goalID: goalID).first
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, summary)
        XCTAssertEqual(loaded?.allowAIContext, true)
        XCTAssertEqual(loaded?.assumptions, ["假设每周有英文周会"])
    }
}
