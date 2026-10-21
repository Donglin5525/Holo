//
//  GoalReviewAndAdjustmentTests.swift
//  HoloTests
//
//  目标闭环·回顾索引与修正提交（最终规格 §6.4 / §6.5；验收 R16 R17 R24 R25 R26 R27 R28 R30 R32 R33 R34 R35）
//  - 线上草案映射：合法保留 / 目标或版本不符整份丢弃 / 非法操作丢弃
//  - 档案归类：goalScope 权威优先于关键词（存钱目标报告不进财务）
//  - 回顾索引：同依据去重、按报告消息反查、到期判定（上次完成 + 周期）
//  - 修正提交：同 goalID 升版不建新目标；幂等；原意保护；依据变化拦停；
//    原子失败零残留；共享习惯改名拒绝；期次按当前资金重算（4800→3300）；并发分叉识别
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalReviewAndAdjustmentTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private let goalID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let revisionID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let reviewID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let reportMessageID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, [
            "Goal", "GoalPlanRevisionMO", "GoalReviewLinkMO", "GoalWorkshopSessionMO",
            "TodoTask", "Habit", "HabitRecord", "Account", "Transaction", "Budget",
        ])
    }

    // MARK: - 夹具

    private func makeScope(digest: String = "digest-1",
                           windowStart: Date = Date().addingTimeInterval(-14 * 86_400),
                           windowEnd: Date = Date(),
                           cutoff: Date = Date()) -> HoloAgentGoalScope {
        HoloAgentGoalScope(goalID: goalID, planRevisionID: revisionID, reviewID: reviewID,
                           windowStart: windowStart, windowEndExclusive: windowEnd,
                           snapshotCutoffAt: cutoff, timeZoneID: "Asia/Shanghai", sourceDigest: digest)
    }

    private func makeRendered(goalScope: HoloAgentGoalScope?) -> HoloRenderedAgentResult {
        var rendered = HoloRenderedAgentResult(title: "北海道资金回顾", summary: "落后 1200", sections: [], evidenceReferences: [])
        rendered.goalScope = goalScope
        return rendered
    }

    /// 目标 + 生效计划 v1（ledger 单账户）+ 回顾索引行（已完成）
    @discardableResult
    private func makeBaselineGoal(digest: String = "digest-1", linkStatus: String = "completed") throws -> Goal {
        let account = Account.create(in: context, name: "旅行基金", type: AccountType.bank.rawValue)
        let tx = Transaction(context: context)
        tx.id = UUID()
        tx.amount = NSDecimalNumber(decimal: 4800)
        tx.type = TransactionType.income.rawValue
        tx.date = Date().addingTimeInterval(-5 * 86_400)
        tx.account = account
        tx.createdAt = tx.date
        tx.updatedAt = tx.date

        let goal = Goal.create(in: context, title: "北海道旅行资金", summary: nil, domain: .finance,
                               desiredOutcome: "出发前专款 18000 元", motivation: nil,
                               deadline: Date().addingTimeInterval(110 * 86_400), allowAIContext: true)
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 18000

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(originalWish: "北海道旅行", successCriteria: "出发前专款 18000 元", deadline: goal.deadline),
            resultSource: GoalPlanResultSourceV2(sourceType: .ledger, sourceID: account.id, unit: "元",
                                                 aggregation: .sum, comparison: .reach, targetValue: 18000,
                                                 baselineValue: nil, baselineObservedAt: nil, freshnessDays: nil,
                                                 ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)),
            bindings: [],
            fundSchedule: (1...6).map { index in
                GoalFundInstallmentV2(dueDate: Date().addingTimeInterval(Double(index - 3) * 30 * 86_400), amount: 3000)
            },
            review: GoalPlanReviewV2(cadenceDays: 7, nextReviewAt: Date().addingTimeInterval(7 * 86_400),
                                     observationWindowDays: 14, verificationFocus: []),
            basis: GoalPlanDecisionBasisV2(origin: .workshop, sourceSessionID: nil, sourceReportMessageID: nil, confirmedAt: Date())
        )
        _ = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                                                      revisionNumber: 1, baseRevisionID: nil,
                                                      operationID: UUID(), effectiveFrom: Date().addingTimeInterval(-60 * 86_400),
                                                      payload: payload, legacySummary: nil)
        let link = GoalReviewLinkMO(context: context)
        link.id = UUID()
        link.schemaVersion = 1
        link.goalID = goal.id
        link.planRevisionID = revisionID
        link.reviewID = reviewID
        link.reportMessageID = reportMessageID
        link.windowStart = Date().addingTimeInterval(-14 * 86_400)
        link.windowEndExclusive = Date().addingTimeInterval(86_400)
        link.snapshotCutoffAt = Date()
        link.timeZoneID = "Asia/Shanghai"
        link.sourceDigest = digest
        link.statusRaw = linkStatus
        link.createdAt = Date().addingTimeInterval(-86_400)
        link.updatedAt = Date()
        if linkStatus == "completed" { link.completedAt = Date().addingTimeInterval(-86_400) }
        try context.save()

        // 让 payload 的 revisionID 与 scope 对齐（scope 用固定 revisionID）
        let row = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)
        row?.id = revisionID
        try context.save()
        return goal
    }

    /// 修正草案（可注入操作与摘要）
    private func makeDraft(goalID: UUID, baseRevisionID: UUID, digest: String = "digest-1",
                           ops: [GoalAdjustmentOperationV2], now: Date = Date()) -> GoalAdjustmentDraftV2 {
        GoalAdjustmentDraftV2(draftID: UUID(), goalID: goalID, baseRevisionID: baseRevisionID,
                              sourceReportMessageID: reportMessageID, sourceDigest: digest,
                              createdAt: now.addingTimeInterval(-3600),
                              expiresAt: now.addingTimeInterval(6 * 24 * 3600),
                              operations: ops, expectedObservation: "先看四周后资金")
    }

    private func commit(_ draft: GoalAdjustmentDraftV2, goalID: UUID,
                        criteriaConfirmed: Bool = false,
                        facts: GoalAdjustmentCommitService.PreparedFacts =
                            GoalAdjustmentCommitService.PreparedFacts(freshDigest: "digest-1", currentFunds: nil)) throws -> GoalAdjustmentCommitReceipt {
        try GoalAdjustmentCommitService.performCommit(
            input: GoalAdjustmentCommitInput(goalID: goalID, draft: draft,
                                             criteriaChangeConfirmed: criteriaConfirmed, now: Date()),
            facts: facts,
            in: context
        )
    }

    // MARK: - 线上草案映射（R16 前置）

    private func makeWire(draftID: String = UUID().uuidString,
                          goalID: String? = nil,
                          baseRevisionID: String? = nil,
                          operations: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft.Operation] = [])
        -> HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft {
        HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft(
            schemaVersion: 1,
            draftID: draftID,
            goalID: goalID ?? goalID_Reference,
            baseRevisionID: baseRevisionID ?? revisionID.uuidString,
            sourceDigest: "digest-1",
            createdAt: "2026-10-20T10:00:00+08:00",
            expiresAt: "2026-10-27T10:00:00+08:00",
            expectedObservation: "先看资金",
            operations: operations
        )
    }

    private var goalID_Reference: String { goalID.uuidString }

    func testWireMapperMapsValidDraftAndDropsInvalidOps() throws {
        let opUpdate = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft.Operation(
            id: "op-1", kind: "update_review", review: .init(cadenceDays: 14, nextReviewAt: "2026-11-01T09:00:00+08:00", observationWindowDays: 14, verificationFocus: ["奶茶次数"]))
        let opBad = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft.Operation(
            id: "op-2", kind: "drop_database")
        let mapped = try XCTUnwrap(GoalAdjustmentDraftWireMapper.map(
            makeWire(operations: [opUpdate, opBad]), scope: makeScope(), reportMessageID: reportMessageID))
        XCTAssertEqual(mapped.goalID, goalID)
        XCTAssertEqual(mapped.baseRevisionID, revisionID)
        XCTAssertEqual(mapped.sourceReportMessageID, reportMessageID)
        XCTAssertEqual(mapped.operations.map(\.id), ["op-1"], "未知 kind 的操作被丢弃")
        XCTAssertEqual(mapped.operations.first?.review?.cadenceDays, 14)
        XCTAssertEqual(mapped.operations.first?.review?.nextReviewAt,
                       GoalAdjustmentDraftWireMapper.parseDate("2026-11-01T09:00:00+08:00"))
        XCTAssertFalse(mapped.isExpired(at: Date(timeIntervalSince1970: 1_792_995_600)))
    }

    func testWireMapperRejectsScopeMismatchEntirely() {
        XCTAssertNil(GoalAdjustmentDraftWireMapper.map(makeWire(goalID: UUID().uuidString), scope: makeScope(), reportMessageID: reportMessageID))
        XCTAssertNil(GoalAdjustmentDraftWireMapper.map(makeWire(baseRevisionID: UUID().uuidString), scope: makeScope(), reportMessageID: reportMessageID))
        XCTAssertNil(GoalAdjustmentDraftWireMapper.map(nil, scope: makeScope(), reportMessageID: reportMessageID))
    }

    // MARK: - 档案归类（R17）

    func testArchiveScenarioTagPrioritizesGoalScopeOverKeywords() {
        let question = "这个月餐饮预算超了多少，存钱进度怎么样"
        // 无 scope：按关键词本会归财务
        XCTAssertEqual(ChatMessageRepository.archiveScenarioTag(rendered: makeRendered(goalScope: nil), question: question), .finance)
        // 有 scope：权威归类为目标——目标筛选中不消失
        XCTAssertEqual(ChatMessageRepository.archiveScenarioTag(rendered: makeRendered(goalScope: makeScope()), question: question), .goal)
    }

    // MARK: - 回顾索引（R14/R16/R19）

    func testReviewLinkDedupeLookupAndDueLogic() throws {
        let goal = Goal.create(in: context, title: "目标", summary: nil, domain: .other,
                               desiredOutcome: nil, motivation: nil, deadline: nil, allowAIContext: true)
        try context.save()
        XCTAssertNil(GoalReviewCoordinator.matchingLink(scope: makeScope(), in: context), "无索引时无去重命中")

        let link = try GoalReviewCoordinator.createLink(in: context, scope: makeScope(), reportMessageID: reportMessageID)
        XCTAssertEqual(link.statusRaw, "running")
        XCTAssertEqual(GoalReviewCoordinator.matchingLink(scope: makeScope(), in: context)?.reviewID, reviewID, "同依据生成中直接恢复")
        XCTAssertEqual(GoalReviewCoordinator.link(reportMessageID: reportMessageID, in: context)?.reviewID, reviewID, "按报告消息反查")

        // 依据变化（digest 不同）→ 不命中，允许新建
        XCTAssertNil(GoalReviewCoordinator.matchingLink(scope: makeScope(digest: "digest-2"), in: context))

        // 无 v2 计划不到期；有计划按 nextReviewAt；完成后按 上次完成 + 周期
        XCTAssertFalse(GoalReviewCoordinator.isReviewDue(goalID: goal.id, in: context))
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(), resultSource: nil, bindings: [],
            review: GoalPlanReviewV2(cadenceDays: 7, nextReviewAt: Date().addingTimeInterval(-1), observationWindowDays: 14, verificationFocus: []),
            basis: GoalPlanDecisionBasisV2(origin: .workshop, sourceSessionID: nil, sourceReportMessageID: nil, confirmedAt: Date())
        )
        _ = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                                                      revisionNumber: 1, baseRevisionID: nil, operationID: nil,
                                                      effectiveFrom: Date(), payload: payload, legacySummary: nil)
        XCTAssertTrue(GoalReviewCoordinator.isReviewDue(goalID: goal.id, in: context), "首个 nextReviewAt 已过 → 到期")

        let completed = GoalReviewLinkMO(context: context)
        completed.id = UUID()
        completed.schemaVersion = 1
        completed.goalID = goal.id
        completed.planRevisionID = revisionID
        completed.reviewID = UUID()
        completed.reportMessageID = UUID()
        completed.windowStart = Date().addingTimeInterval(-14 * 86_400)
        completed.windowEndExclusive = Date()
        completed.snapshotCutoffAt = Date()
        completed.timeZoneID = "Asia/Shanghai"
        completed.sourceDigest = "d"
        completed.statusRaw = "completed"
        completed.completedAt = Date().addingTimeInterval(-3 * 86_400)
        completed.createdAt = Date().addingTimeInterval(-4 * 86_400)
        completed.updatedAt = Date()
        try context.save()
        XCTAssertFalse(GoalReviewCoordinator.isReviewDue(goalID: goal.id, in: context), "上次完成 3 天前 < 周期 7 天 → 未到期")

        completed.completedAt = Date().addingTimeInterval(-8 * 86_400)
        try context.save()
        XCTAssertTrue(GoalReviewCoordinator.isReviewDue(goalID: goal.id, in: context), "上次完成 8 天前 ≥ 周期 → 到期")
    }

    // MARK: - 修正提交（R24 R25 R26 R27 R28 R30 R32 R33 R34 R35）

    func testAdjustmentCreatesNewRevisionSameGoalNotNewGoal() throws {
        let goal = try makeBaselineGoal()
        let beforeGoalCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Goal"))
        let bindingID = UUID()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-review", kind: .updateReview,
                                      review: GoalPlanReviewV2(cadenceDays: 14, nextReviewAt: Date().addingTimeInterval(14 * 86_400), observationWindowDays: 14, verificationFocus: ["奶茶"])),
            GoalAdjustmentOperationV2(id: "op-end", kind: .endBinding, targetBindingID: bindingID),
        ])
        // endBinding 引用不存在的绑定应失败——这里改用存在的结构：仅提交 review 变更验证 R25 主线
        let cleanDraft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [draft.operations[0]])
        let receipt = try commit(cleanDraft, goalID: goal.id)

        XCTAssertFalse(receipt.wasIdempotentReplay)
        XCTAssertEqual(receipt.revisionNumber, 2, "同 goalID 升到第 2 版")
        let goals = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Goal"))
        XCTAssertEqual(goals, beforeGoalCount, "不新建另一个目标")
        let row = try XCTUnwrap(GoalPlanRevisionStore.revisionRow(id: receipt.revisionID, in: context))
        XCTAssertEqual(row.baseRevisionID, revisionID, "父版本指向基础版本")
        XCTAssertEqual(row.operationID, cleanDraft.draftID, "幂等键 = draftID")
        XCTAssertEqual(row.planPayloadV2?.review?.cadenceDays, 14)
        XCTAssertEqual(row.planPayloadV2?.basis.origin, .adjustment)
        XCTAssertEqual(row.planPayloadV2?.basis.sourceReportMessageID, reportMessageID)
    }

    func testAdjustmentIdempotentReplayAppliesOnce() throws {
        let goal = try makeBaselineGoal()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-review", kind: .updateReview, review: GoalPlanReviewV2(cadenceDays: 14, nextReviewAt: nil, observationWindowDays: 14, verificationFocus: [])),
        ])
        let first = try commit(draft, goalID: goal.id)
        XCTAssertFalse(first.wasIdempotentReplay)
        let second = try commit(draft, goalID: goal.id)
        XCTAssertTrue(second.wasIdempotentReplay, "重复点按/重试只一次生效")
        XCTAssertEqual(second.revisionID, first.revisionID)
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 2, "基线 1 版 + 调整 1 版，不重复升版")
    }

    func testCriteriaChangeRequiresSeparateConfirmation() throws {
        let goal = try makeBaselineGoal()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-criteria", kind: .changeSuccessCriteria,
                                      criteriaChange: GoalAdjustmentCriteriaChangeV2(newTargetValue: 15000, reason: "赶不上")),
        ])
        XCTAssertThrowsError(try commit(draft, goalID: goal.id, criteriaConfirmed: false)) { error in
            XCTAssertEqual(error as? GoalAdjustmentCommitError, .separateConfirmationRequired)
        }
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 1, "未确认不升版不改目标")
        let receipt = try commit(draft, goalID: goal.id, criteriaConfirmed: true)
        XCTAssertEqual(receipt.appliedOperationIDs, ["op-criteria"])
        let payload = GoalPlanRevisionStore.revisionRow(id: receipt.revisionID, in: context)?.planPayloadV2
        XCTAssertEqual(payload?.resultSource?.targetValue, 15000, "确认后总目标改为 15000")
        XCTAssertEqual(GoalAdjustmentCommitService.fetchGoal(id: goal.id, in: context)?.metricTargetValueDouble, 15000, "Goal 当前配置同步")
    }

    func testSourceDigestChangeStopsApplication() throws {
        let goal = try makeBaselineGoal()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, digest: "digest-stale", ops: [
            GoalAdjustmentOperationV2(id: "op-review", kind: .updateReview, review: GoalPlanReviewV2(cadenceDays: 14, nextReviewAt: nil, observationWindowDays: 14, verificationFocus: [])),
        ])
        // 事实：当前摘要仍是 digest-1（补记后重算会得到不同值）
        XCTAssertThrowsError(try commit(draft, goalID: goal.id)) { error in
            XCTAssertEqual(error as? GoalAdjustmentCommitError, .sourceDigestChanged, "补记资金后旧建议不能直接采纳")
        }
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 1, "拦停时不升版")
    }

    func testExpiredDraftRejected() throws {
        let goal = try makeBaselineGoal()
        let now = Date()
        let draft = GoalAdjustmentDraftV2(draftID: UUID(), goalID: goal.id, baseRevisionID: revisionID,
                                          sourceReportMessageID: reportMessageID, sourceDigest: "digest-1",
                                          createdAt: now.addingTimeInterval(-8 * 24 * 3600),
                                          expiresAt: now.addingTimeInterval(-24 * 3600),
                                          operations: [
                                            GoalAdjustmentOperationV2(id: "op-review", kind: .updateReview, review: GoalPlanReviewV2(cadenceDays: 14, nextReviewAt: nil, observationWindowDays: 14, verificationFocus: [])),
                                          ], expectedObservation: nil)
        XCTAssertThrowsError(try commit(draft, goalID: goal.id)) { error in
            guard case .draftExpired? = error as? GoalAdjustmentCommitError else { return XCTFail("\(error)") }
        }
    }

    func testAtomicFailureLeavesNoPartialData() throws {
        let goal = try makeBaselineGoal()
        let habitsBefore = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Habit"))
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-habit", kind: .createHabit, draftRef: "h1",
                                      habitSpec: GoalAdjustmentHabitSpecV2(name: "奶茶记录", frequency: "daily", type: "numeric", unit: "杯")),
            GoalAdjustmentOperationV2(id: "op-task", kind: .reuseTask, targetEntityID: UUID()),
        ])
        XCTAssertThrowsError(try commit(draft, goalID: goal.id)) { error in
            guard case .objectMissing? = error as? GoalAdjustmentCommitError else { return XCTFail("\(error)") }
        }
        context.rollback()
        let habitsAfter = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Habit"))
        XCTAssertEqual(habitsAfter, habitsBefore, "第二步失败，第一步建的习惯不得残留")
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 1, "不升版")
    }

    func testSharedHabitRenameRejectedButFrequencyOk() throws {
        let goal = try makeBaselineGoal()
        let otherGoal = Goal.create(in: context, title: "别的目标", summary: nil, domain: .health,
                                    desiredOutcome: nil, motivation: nil, deadline: nil, allowAIContext: true)
        let shared = Habit.create(in: context, name: "听读英语", icon: "book", color: "#000", type: .checkIn)
        shared.goal = otherGoal
        try context.save()

        let rename = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-rename", kind: .updateHabit, targetEntityID: shared.id,
                                      habitSpec: GoalAdjustmentHabitSpecV2(name: "口语练习", frequency: "daily", type: "checkIn")),
        ])
        XCTAssertThrowsError(try commit(rename, goalID: goal.id)) { error in
            guard case .validation(let reason)? = error as? GoalAdjustmentCommitError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("不能改名"))
        }
        XCTAssertEqual(shared.goal?.id, otherGoal.id, "共享习惯父引用不动")
        XCTAssertEqual(shared.name, "听读英语", "口语练习不得靠改名继承听读的次数")

        // 频次调整保存为本目标要求，不更改共享习惯的默认值
        let adjust = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-freq", kind: .updateHabit, targetEntityID: shared.id,
                                      habitSpec: GoalAdjustmentHabitSpecV2(name: "听读英语", frequency: "weekly", type: "checkIn")),
        ])
        let receipt = try commit(adjust, goalID: goal.id)
        XCTAssertEqual(receipt.appliedOperationIDs, ["op-freq"])
        XCTAssertEqual(shared.frequency, HabitFrequency.daily.rawValue)
        let editedPlan = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)?.planPayloadV2
        XCTAssertEqual(editedPlan?.bindings.first(where: { $0.entityID == shared.id })?.requirement?.windowDays, 7)
        XCTAssertEqual(shared.goal?.id, otherGoal.id, "调整频次不抢父引用")
    }

    func testAdjustmentCanSetGoalLocalZeroLimitWithoutChangingSharedHabit() throws {
        let goal = try makeBaselineGoal()
        let shared = Habit.create(in: context, name: "宵夜", icon: "moon", color: "#000", type: .numeric,
            targetValue: 9, unit: "次", isBadHabit: true)
        try context.save()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-zero-cap", kind: .updateHabit, targetEntityID: shared.id, role: .constraint,
                habitSpec: GoalAdjustmentHabitSpecV2(name: "宵夜", frequency: "weekly", type: "numeric", unit: "次", constraintLimit: 0)),
        ])
        _ = try commit(draft, goalID: goal.id)
        let plan = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)?.planPayloadV2
        let rule = plan?.bindings.first { $0.entityID == shared.id }?.requirement
        XCTAssertEqual(rule?.target, 0)
        XCTAssertEqual(rule?.comparison, .stayBelow)
        XCTAssertEqual(shared.targetValue?.doubleValue, 9)
        XCTAssertNil(shared.goal)
    }

    func testFundScheduleRecomputedFromCurrentFunds() throws {
        let goal = try makeBaselineGoal() // 账户 4800；期次 6×3000（2 期已过）
        let future = (0..<4).map { GoalFundInstallmentV2(dueDate: Date().addingTimeInterval(Double($0 + 1) * 25 * 86_400), amount: 3300) }
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-fund", kind: .updateFundSchedule, fundSchedule: future,
                                      currentSummary: "每期 3000", proposedSummary: "每期 3300"),
        ])
        let receipt = try commit(draft, goalID: goal.id,
                                 facts: .init(freshDigest: "digest-1", currentFunds: 4800))
        XCTAssertEqual(receipt.recomputedPerInstallment, 3300, "剩余 (18000-4800)/4 = 3300")
        let payload = GoalPlanRevisionStore.revisionRow(id: receipt.revisionID, in: context)?.planPayloadV2
        XCTAssertEqual(payload?.fundSchedule.count, 4)
        XCTAssertTrue(payload?.fundSchedule.allSatisfy { $0.amount == 3300 } == true, "期次金额按当前资金重算，不采旧建议")

        // R27：补记到 6000 后，同一草案重交 → 摘要未变但资金不同 → 重算为 3000
        let replenish = makeDraft(goalID: goal.id, baseRevisionID: receipt.revisionID, digest: "digest-2", ops: [
            GoalAdjustmentOperationV2(id: "op-fund2", kind: .updateFundSchedule, fundSchedule: future),
        ])
        let link = GoalReviewCoordinator.link(reportMessageID: reportMessageID, in: context)
        link?.sourceDigest = "digest-2"
        try context.save()
        let receipt2 = try commit(replenish, goalID: goal.id,
                                  facts: .init(freshDigest: "digest-2", currentFunds: 6000))
        XCTAssertEqual(receipt2.recomputedPerInstallment, 3000, "补至 6000 后重算为 3000，旧 3300 建议失效")
    }

    func testConcurrentBranchDetectedWhenBaseHasCommittedChildren() throws {
        let goal = try makeBaselineGoal()
        // 模拟另一设备已基于同一父版本提交了子版本
        let payload = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)?.planPayloadV2
        _ = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                                                      revisionNumber: 2, baseRevisionID: revisionID,
                                                      operationID: UUID(), effectiveFrom: Date(),
                                                      payload: payload ?? GoalPlanPayloadV2(
                                                        intent: GoalPlanIntentV2(), resultSource: nil, bindings: [],
                                                        basis: GoalPlanDecisionBasisV2(origin: .adjustment, sourceSessionID: nil, sourceReportMessageID: nil, confirmedAt: Date())),
                                                      legacySummary: nil)
        try context.save()

        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-review", kind: .updateReview, review: GoalPlanReviewV2(cadenceDays: 14, nextReviewAt: nil, observationWindowDays: 14, verificationFocus: [])),
        ])
        XCTAssertThrowsError(try commit(draft, goalID: goal.id)) { error in
            switch error as? GoalAdjustmentCommitError {
            case .concurrentBranchDetected, .baseRevisionChanged:
                break // 同父分叉或基础已非最新：都属「待合并」，不静默覆盖
            default:
                XCTFail("应为分叉/基线变更错误：\(error)")
            }
        }
    }

    func testBudgetConflictOnCreateRejected() throws {
        let goal = try makeBaselineGoal()
        let account = try XCTUnwrap(try context.fetch(NSFetchRequest<Account>(entityName: "Account")).first)
        _ = Budget.create(in: context, accountId: account.id, amount: NSDecimalNumber(value: 2000), period: .month, startDate: Date())
        try context.save()
        let draft = makeDraft(goalID: goal.id, baseRevisionID: revisionID, ops: [
            GoalAdjustmentOperationV2(id: "op-budget", kind: .createBudget,
                                      budgetRule: GoalBudgetRuleV2(bindingID: UUID(), accountID: account.id, categoryID: nil,
                                                                   amount: 1500, period: "month", startDate: Date(), reuseExistingBudgetID: nil)),
        ])
        XCTAssertThrowsError(try commit(draft, goalID: goal.id)) { error in
            XCTAssertEqual(error as? GoalAdjustmentCommitError, .budgetConflict)
        }
        context.rollback()
        let budgets = try context.fetch(NSFetchRequest<Budget>(entityName: "Budget"))
        XCTAssertEqual(budgets.count, 1, "不静默新建第二份预算")
        XCTAssertEqual(budgets.first?.amount.decimalValue, 2000, "既有预算不被偷改")
    }
}
