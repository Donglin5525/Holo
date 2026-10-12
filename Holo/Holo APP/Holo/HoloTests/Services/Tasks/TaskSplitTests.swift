//
//  TaskSplitTests.swift
//  HoloTests
//
//  「拆成几步」拆开瘦身单测（2026-10-11 定稿）
//  解析宽松接收 / 拆解落库 / 等待态切换 / 候选词编解码 / 存量迁移 / 提示词组装
//

import XCTest
import CoreData
@testable import Holo

final class TaskSplitTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var todoRepo: TodoRepository!

    override func setUpWithError() throws {
        let model = CoreDataTestSupport.sharedModel
        container = NSPersistentContainer(name: "TaskSplitTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        todoRepo = TodoRepository(context: container.viewContext)
        CoreDataTestSupport.retain(container, todoRepo)
    }

    private func makeTask(title: String = "办日本签证") throws -> TodoTask {
        try todoRepo.createTask(title: title)
    }

    // MARK: - 1. 解析（宽松接收）

    func test_解析_proposal带等待标注与候选词() throws {
        let raw = """
        {"kind":"proposal","outcomeSummary":"s","verificationPrompt":"v","patch":{"mode":"prepend_preparation","newSteps":[
          {"ref":"s1","action":"导出银行流水","doneWhen":"拿到PDF","waiting":false,"waitHints":["等账单日","等银行APP"]},
          {"ref":"s2","action":"等出签","doneWhen":"护照到手","waiting":true,"waitNote":"等出签","waitHints":["等5个工作日"]}
        ]}}
        """
        let outcome = try TaskSplitParser.parse(raw)
        guard case .steps(let drafts) = outcome else {
            return XCTFail("应为 steps，实际 \(outcome)")
        }
        XCTAssertEqual(drafts.count, 2)
        XCTAssertFalse(drafts[0].isWaiting)
        XCTAssertEqual(drafts[0].waitHints, ["等账单日", "等银行APP"])
        XCTAssertTrue(drafts[1].isWaiting)
        XCTAssertEqual(drafts[1].waitNote, "等出签")
    }

    func test_解析_模型未照做扩展字段时降级为普通步骤() throws {
        // 服务端契约只有 ref/action/doneWhen——waiting/waitHints 缺席是正常降级路径
        let raw = """
        {"kind":"proposal","patch":{"mode":"refine","newSteps":[{"ref":"a","action":"第一步","doneWhen":"ok"}]}}
        """
        let outcome = try TaskSplitParser.parse(raw)
        guard case .steps(let drafts) = outcome else {
            return XCTFail("应为 steps，实际 \(outcome)")
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertFalse(drafts[0].isWaiting)
        XCTAssertTrue(drafts[0].waitNote.isEmpty)
        XCTAssertTrue(drafts[0].waitHints.isEmpty)
    }

    func test_解析_顶层steps兼容_澄清与帮不上() throws {
        let top = try TaskSplitParser.parse(#"{"kind":"proposal","steps":[{"action":"先查材料"}]}"#)
        guard case .steps(let drafts) = top, drafts.count == 1 else {
            return XCTFail("顶层 steps 应兼容，实际 \(top)")
        }

        let clarify = try TaskSplitParser.parse(#"{"kind":"clarification","question":"何时出发？","suggestedAnswers":["两周内"]}"#)
        guard case .clarification(let q, let answers) = clarify else {
            return XCTFail("应为 clarification，实际 \(clarify)")
        }
        XCTAssertEqual(q, "何时出发？")
        XCTAssertEqual(answers, ["两周内"])

        let cannot = try TaskSplitParser.parse(#"{"kind":"cannotHelp","reason":"这不是任务"}"#)
        guard case .cannotHelp(let reason) = cannot else {
            return XCTFail("应为 cannotHelp，实际 \(cannot)")
        }
        XCTAssertEqual(reason, "这不是任务")
    }

    // MARK: - 2. 拆解落库

    func test_拆解落库_序号接续且等待步带标注与候选() throws {
        let task = try makeTask()
        try todoRepo.addCheckItem(title: "已有步骤", to: task, order: 0)

        let drafts = [
            TaskSplitStepDraft(title: "买旅行保险"),
            TaskSplitStepDraft(title: "等出签", isWaiting: true, waitNote: "等出签", waitHints: ["等5个工作日"])
        ]
        let items = try todoRepo.addSplitSteps(drafts, to: task)

        XCTAssertEqual(items.count, 2)
        let sorted = ((task.checkItems?.allObjects as? [CheckItem]) ?? []).sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].title, "已有步骤")
        XCTAssertEqual(sorted[1].title, "买旅行保险")
        XCTAssertEqual(sorted[2].order, 2)
        XCTAssertTrue(sorted[2].isWaiting)
        XCTAssertEqual(sorted[2].waitNote, "等出签")
        XCTAssertEqual(sorted[2].waitHints, ["等5个工作日"])
    }

    // MARK: - 3. 等待态切换

    func test_标记等待与恢复_字段与提醒时间() throws {
        let task = try makeTask()
        let item = try todoRepo.addCheckItem(title: "等同事回话", to: task, order: 0)
        let remindAt = Date().addingTimeInterval(3600)

        try todoRepo.setCheckItemWaiting(item, note: "等同事回话", remindAt: remindAt)
        XCTAssertTrue(item.isWaiting)
        XCTAssertEqual(item.waitNote, "等同事回话")
        XCTAssertEqual(item.reviewRemindAt, remindAt)

        try todoRepo.resumeCheckItem(item)
        XCTAssertFalse(item.isWaiting)
        XCTAssertNil(item.waitNote)
        XCTAssertNil(item.reviewRemindAt)
    }

    func test_勾掉等待步_等待态随动清空() throws {
        let task = try makeTask()
        let item = try todoRepo.addCheckItem(title: "等出签", to: task, order: 0)
        try todoRepo.setCheckItemWaiting(item, note: "等出签", remindAt: Date())

        try todoRepo.toggleCheckItem(item)
        XCTAssertTrue(item.isChecked)
        XCTAssertFalse(item.isWaiting)
        XCTAssertNil(item.waitNote)
        XCTAssertNil(item.reviewRemindAt)
    }

    // MARK: - 4. 候选词编解码

    func test_waitHints_JSON编解码往返与空值清空() throws {
        let task = try makeTask()
        let item = try todoRepo.addCheckItem(title: "步骤", to: task, order: 0)

        item.waitHints = ["等账单日", "等银行APP"]
        try container.viewContext.save()
        XCTAssertEqual(item.waitHints, ["等账单日", "等银行APP"])

        item.waitHints = []
        try container.viewContext.save()
        XCTAssertNil(item.waitHintsJSON)
        XCTAssertTrue(item.waitHints.isEmpty)
    }

    // MARK: - 5. 存量迁移

    private func insertStep(
        taskID: UUID, revisionID: UUID, kind: String, action: String?,
        state: String, orderHint: TimeInterval, waitReason: String? = nil,
        reviewAfter: Date? = nil, sourceCheckItemID: UUID? = nil
    ) {
        let step = HoloTaskExecutionStep(context: container.viewContext)
        step.id = UUID()
        step.taskID = taskID
        step.originRevisionID = revisionID
        step.kindRaw = kind
        step.actionText = action
        step.stateRaw = state
        step.stateVersion = 1
        step.createdAt = Date(timeIntervalSince1970: 1000 + orderHint)
        step.updatedAt = step.createdAt
        step.waitReason = waitReason
        step.reviewAfter = reviewAfter
        step.sourceCheckItemID = sourceCheckItemID
    }

    func test_迁移_执行步骤转子任务_完成等待引用三类() throws {
        let task = try makeTask()
        let referenced = try todoRepo.addCheckItem(title: "既有清单项", to: task, order: 0)
        let revisionID = UUID()

        insertStep(taskID: task.id, revisionID: revisionID, kind: "action", action: "递材料", state: "done", orderHint: 1)
        insertStep(taskID: task.id, revisionID: revisionID, kind: "action", action: "等出签", state: "waiting", orderHint: 2, waitReason: "等出签", reviewAfter: Date(timeIntervalSince1970: 999_999))
        insertStep(taskID: task.id, revisionID: revisionID, kind: "action", action: "取护照", state: "pending", orderHint: 3)
        insertStep(taskID: task.id, revisionID: revisionID, kind: "sourceCheckItemReference", action: nil, state: "waiting", orderHint: 4, waitReason: "等盖章", sourceCheckItemID: referenced.id)
        // 旧版本残留（非活动版本）：不迁
        insertStep(taskID: task.id, revisionID: UUID(), kind: "action", action: "废弃旧步骤", state: "pending", orderHint: 0)

        task.executionSchemaVersion = 1
        task.activeExecutionRevisionID = revisionID
        try container.viewContext.save()

        let migrated = try TaskExecutionMigration.migrateAll(in: container.viewContext)
        XCTAssertEqual(migrated, 1)

        let sorted = ((task.checkItems?.allObjects as? [CheckItem]) ?? []).sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.count, 4) // 既有1 + 转换3（引用步不建第二份）
        XCTAssertEqual(sorted[0].title, "既有清单项")
        XCTAssertTrue(sorted[0].isWaiting)      // 引用步的等待态回写
        XCTAssertEqual(sorted[0].waitNote, "等盖章")

        XCTAssertEqual(sorted[1].title, "递材料")
        XCTAssertTrue(sorted[1].isChecked)       // done → 已勾选
        XCTAssertEqual(sorted[2].title, "等出签")
        XCTAssertTrue(sorted[2].isWaiting)
        XCTAssertEqual(sorted[2].waitNote, "等出签")
        XCTAssertNotNil(sorted[2].reviewRemindAt)
        XCTAssertEqual(sorted[3].title, "取护照")
        XCTAssertFalse(sorted[3].isChecked)

        XCTAssertEqual(task.executionSchemaVersion, 0)
        XCTAssertNil(task.activeExecutionRevisionID)
    }

    func test_迁移_无接管任务零变化() throws {
        _ = try makeTask()
        XCTAssertEqual(try TaskExecutionMigration.migrateAll(in: container.viewContext), 0)
    }

    // MARK: - 6. 提示词组装

    func test_提示词_带已有步骤与澄清回答() throws {
        let task = try makeTask()
        try todoRepo.addCheckItem(title: "已有一步", to: task, order: 0)

        let prompt = TaskSplitService.makePrompt(task: task, userAnswer: "两周内出发", requestID: "r-1")
        XCTAssertTrue(prompt.contains("existingSteps"))
        XCTAssertTrue(prompt.contains("已有一步"))
        XCTAssertTrue(prompt.contains("两周内出发"))
        XCTAssertTrue(prompt.contains("只提议还缺的补充步骤"))
        XCTAssertTrue(prompt.contains("\"waiting\""))
        XCTAssertTrue(prompt.contains("waitHints"))
    }
}
