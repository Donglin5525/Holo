//
//  GoalWorkshopCommitTests.swift
//  HoloTests
//
//  目标共创原子提交测试（方案任务 6）：失败注入（任务第 2 项失败/习惯失败/save 失败）、
//  双击与重复请求幂等、旧版本草案、授权关闭、未选行动不创建、成功路径一致性、
//  旧链路 saveDraft 复用事务。任何中途失败不得留下半套数据。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalWorkshopCommitTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, [
            "GoalWorkshopSessionMO", "GoalPlanRevisionMO",
            "Goal", "TodoTask", "Habit", "TodoList", "CheckItem",
        ])
        GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailSave = nil
    }

    override func tearDown() async throws {
        GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailSave = nil
    }

    // MARK: - 工厂

    private func makeSession(phase: GoalWorkshopPhase = .reviewing) -> GoalWorkshopSessionV1 {
        var session = GoalWorkshopSessionV1(originalText: "我想在工作会议中更敢开口说英语")
        session.phase = phase
        session.routeOptions = [
            GoalRouteOption(id: "route-1", title: "先练会议听说", fit: "x", effort: "x", tradeoff: "x", reason: "x"),
        ]
        session.selectedRouteID = "route-1"
        session.plan = makePlan()
        return session
    }

    private func makePlan(taskCount: Int = 2, habitCount: Int = 1) -> GoalWorkshopPlan {
        GoalWorkshopPlan(
            draft: GoalDraft(
                id: "draft-1",
                title: "工作会议英语敢开口",
                summary: nil,
                domain: .learning,
                iconEmoji: nil,
                desiredOutcome: "周会发言一次",
                motivation: "跨团队沟通",
                deadlineText: "2026-12-31",
                tasks: (0..<taskCount).map { index in
                    GoalTaskDraft(id: "task-\(index)", isSelected: true, title: "任务\(index)",
                                  dueDateText: "2026-10-0\(index + 1)", priority: 1, note: nil)
                },
                habits: (0..<habitCount).map { index in
                    GoalHabitDraft(id: "habit-\(index)", isSelected: true, name: "习惯\(index)",
                                   frequency: "daily", targetCount: 1, type: "checkIn", unit: nil,
                                   targetValue: nil, isBadHabit: false, successRule: "completeWhenDone")
                },
                missingInfoWarnings: []
            ),
            successEvidence: "连续四周周会发言",
            milestones: [],
            firstActionID: "task-0",
            assumptions: ["每周有英文会"],
            reviewDateText: nil
        )
    }

    private func commit(_ session: GoalWorkshopSessionV1, allowAIContext: Bool = true) throws -> GoalWorkshopCommitReceipt {
        try GoalWorkshopCommitService.performCommit(
            draft: session.plan!.draft,
            allowAIContext: allowAIContext,
            source: "goalWorkshop",
            sourceSessionID: session.id,
            successEvidence: "连续四周周会发言",
            assumptions: session.plan?.assumptions ?? [],
            selectedRouteTitle: "先练会议听说",
            in: context
        )
    }

    private func count(_ entity: String, predicate: NSPredicate? = nil) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        return (try? context.count(for: request)) ?? -1
    }

    private func assertNoPartialData() {
        XCTAssertEqual(count("Goal"), 0, "不得残留 Goal")
        XCTAssertEqual(count("TodoTask"), 0, "不得残留任务")
        XCTAssertEqual(count("Habit"), 0, "不得残留习惯")
        XCTAssertEqual(count("GoalPlanRevisionMO"), 0, "不得残留决策版本")
    }

    // MARK: - 成功路径

    func testSuccessfulCommitWritesEverythingConsistently() throws {
        let session = makeSession()
        // 先持久化会话（模拟已存在的会话行）；retain 缓解 iOS 26.3 模拟器系统级重复释放
        let sessionStore = GoalWorkshopStore(context: context)
        CoreDataTestSupport.retain(sessionStore)
        try sessionStore.saveIfRevisionMatches(session)

        let receipt = try commit(session)

        XCTAssertFalse(receipt.wasIdempotentReplay)
        XCTAssertEqual(receipt.createdTaskCount, 2)
        XCTAssertEqual(receipt.createdHabitCount, 1)
        XCTAssertEqual(count("Goal", predicate: NSPredicate(format: "id == %@", receipt.goalID as CVarArg)), 1)
        XCTAssertEqual(count("TodoTask"), 2)
        XCTAssertEqual(count("Habit"), 1)
        // 决策版本与会话回执同事务写入
        XCTAssertEqual(count("GoalPlanRevisionMO"), 1)
        let sessionRow = try context.fetch(NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")).first
        XCTAssertEqual(sessionRow?.appliedGoalID, receipt.goalID)
        XCTAssertEqual(sessionRow?.phase, .saved)
        // 关联：任务/习惯挂在目标上
        let goal = try context.fetch(NSFetchRequest<Goal>(entityName: "Goal")).first
        XCTAssertEqual(goal?.tasks?.count, 2)
        XCTAssertEqual(goal?.habits?.count, 1)
    }

    func testUnselectedActionsNotCreated() throws {
        var session = makeSession()
        for index in session.plan!.draft.tasks.indices {
            session.plan!.draft.tasks[index].isSelected = false
        }
        for index in session.plan!.draft.habits.indices {
            session.plan!.draft.habits[index].isSelected = false
        }
        let receipt = try commit(session)
        XCTAssertEqual(receipt.createdTaskCount, 0)
        XCTAssertEqual(receipt.createdHabitCount, 0)
        XCTAssertEqual(count("TodoTask"), 0)
        XCTAssertEqual(count("Habit"), 0)
        XCTAssertEqual(count("Goal"), 1, "零行动目标本身仍创建")
    }

    func testAllowAIContextOffRespected() throws {
        let session = makeSession()
        _ = try commit(session, allowAIContext: false)
        let goal = try context.fetch(NSFetchRequest<Goal>(entityName: "Goal")).first
        XCTAssertEqual(goal?.allowAIContext, false)
        let revisionStore = GoalPlanRevisionStore(context: context)
        CoreDataTestSupport.retain(revisionStore)
        let summary = try revisionStore.loadRevisions(goalID: goal!.id).first
        XCTAssertEqual(summary?.allowAIContext, false)
    }

    // MARK: - 失败注入：任何中途失败可安全重试（无半套数据）

    func testTaskFailureLeavesNoPartialData() throws {
        let session = makeSession()
        GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex = { $0 == 1 }  // 第 2 项任务失败

        XCTAssertThrowsError(try commit(session)) { error in
            guard case GoalWorkshopCommitService.CommitError.saveFailed = error else {
                return XCTFail("应抛 saveFailed：\(error)")
            }
        }
        context.rollback()
        assertNoPartialData()

        // 失败后可安全重试：清注入 → 成功
        GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex = nil
        let receipt = try commit(session)
        XCTAssertEqual(receipt.createdTaskCount, 2)
    }

    func testHabitFailureLeavesNoPartialData() throws {
        let session = makeSession()
        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = { _ in true }
        XCTAssertThrowsError(try commit(session))
        context.rollback()
        assertNoPartialData()
    }

    func testSaveFailureLeavesNoPartialData() throws {
        let session = makeSession()
        GoalWorkshopCommitHooks.shared.shouldFailSave = { true }
        XCTAssertThrowsError(try commit(session))
        context.rollback()
        assertNoPartialData()
        GoalWorkshopCommitHooks.shared.shouldFailSave = nil
        _ = try commit(session)
        XCTAssertEqual(count("Goal"), 1, "重试成功")
    }

    // MARK: - 幂等

    func testDoubleCommitIsIdempotent() throws {
        let session = makeSession()
        let first = try commit(session)
        // 双击确认 / 同会话重复请求
        let second = try commit(session)
        XCTAssertTrue(second.wasIdempotentReplay)
        XCTAssertEqual(second.goalID, first.goalID)
        XCTAssertEqual(count("Goal"), 1, "不得重复创建目标")
        XCTAssertEqual(count("TodoTask"), 2)
        XCTAssertEqual(count("Habit"), 1)
    }

    func testOlderSessionRevisionStillIdempotent() throws {
        // 旧草案旧版本：同 sessionID 不同 revision 的会话提交 → 按逻辑 ID 幂等
        let session = makeSession()
        _ = try commit(session)
        var older = session
        older.revision = 1  // 更旧的快照
        let replay = try commit(older)
        XCTAssertTrue(replay.wasIdempotentReplay)
        XCTAssertEqual(count("Goal"), 1)
    }

    func testCrossDeviceLogicalIDMerge() throws {
        // 跨设备同逻辑 ID 副本：另一行 Goal 已带同 sourceSessionID（模拟 iCloud 归并前的双写）
        let session = makeSession()
        let existing = Goal.create(in: context, title: "别处已建的同会话目标", summary: nil, domain: .learning,
                                   desiredOutcome: nil, motivation: nil, deadline: nil, allowAIContext: true)
        existing.sourceSessionID = session.id
        try context.save()

        let replay = try commit(session)
        XCTAssertTrue(replay.wasIdempotentReplay)
        XCTAssertEqual(replay.goalID, existing.id, "按逻辑 ID 归并到既有目标")
        XCTAssertEqual(count("Goal"), 1, "不重复创建")
        XCTAssertEqual(count("TodoTask"), 0, "幂等重放不再创建行动")
    }

    // MARK: - 旧链路复用

    func testLegacySaveDraftUsesSameTransaction() throws {
        let draft = makePlan().draft
        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = { _ in true }

        let repo = GoalRepository(context: context)
        CoreDataTestSupport.retain(repo)
        XCTAssertThrowsError(try repo.saveDraft(draft, allowAIContext: true, source: "holoAI"))
        context.rollback()
        assertNoPartialData()

        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = nil
        let result = try repo.saveDraft(draft, allowAIContext: true, source: "holoAI")
        XCTAssertEqual(result.createdTaskCount, 2)
        XCTAssertEqual(result.createdHabitCount, 1)
        XCTAssertNil(result.goal.sourceSessionID, "旧链路无会话逻辑 ID")
    }

    // MARK: - 校验

    func testEmptyTitleRejectedBeforeAnyWrite() throws {
        var session = makeSession()
        session.plan?.draft.title = "   "
        XCTAssertThrowsError(try commit(session)) { error in
            guard case GoalWorkshopCommitService.CommitError.validation = error else {
                return XCTFail("应抛 validation：\(error)")
            }
        }
        assertNoPartialData()
    }

    func testInvalidDateRejected() throws {
        var session = makeSession()
        session.plan?.draft.deadlineText = "下个月"
        XCTAssertThrowsError(try commit(session)) { error in
            guard case GoalWorkshopCommitService.CommitError.validation = error else {
                return XCTFail("应抛 validation：\(error)")
            }
        }
        assertNoPartialData()
    }
}
