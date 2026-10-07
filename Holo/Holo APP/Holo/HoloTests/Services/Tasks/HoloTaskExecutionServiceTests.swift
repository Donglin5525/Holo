//
//  HoloTaskExecutionServiceTests.swift
//  HoloTests
//
//  分步推进本地核心单测（2026-09-25 实施规格 §12.1 E 矩阵可本地执行项）
//  手工计划即可走完：采纳 → 推进 → 等待 → 恢复 → 结果确认 → 撤回/直接完成。
//

import XCTest
import CoreData
@testable import Holo

final class HoloTaskExecutionServiceTests: XCTestCase {

    // MARK: - 装配

    private func makeStack() throws -> (TodoRepository, NSManagedObjectContext, HoloTaskExecutionService, HoloTaskExecutionRepository) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TaskExecutionTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TodoRepository(context: ctx)
        let service = HoloTaskExecutionService.makeTestService(context: ctx)
        let execRepo = HoloTaskExecutionRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository, service, execRepo)
        return (repository, ctx, service, execRepo)
    }

    private func snapshotFingerprint(_ execRepo: HoloTaskExecutionRepository, taskID: UUID) throws -> String {
        try XCTUnwrap(execRepo.currentSnapshotFingerprint(taskID: taskID))
    }

    /// 采纳一个三步手工计划
    @discardableResult
    private func adoptThreeStepPlan(
        _ repo: TodoRepository,
        _ service: HoloTaskExecutionService,
        _ execRepo: HoloTaskExecutionRepository,
        task: TodoTask,
        fingerprint overrideFingerprint: String? = nil
    ) throws -> HoloTaskExecutionRevision {
        let fingerprint = try overrideFingerprint ?? snapshotFingerprint(execRepo, taskID: task.id)
        return try service.adopt(
            HoloTaskExecutionService.AdoptionInput(
                taskID: task.id,
                expectedFingerprint: fingerprint,
                outcomeSummary: "护照到期日期已记录并核对",
                verificationPrompt: "已经记录日期，并和证件核对一致了吗？",
                requirements: [
                    HoloTaskExecutionRequirement(id: "req-1", content: "日期已记录", source: .taskBody)
                ],
                steps: [
                    HoloTaskExecutionManualStep(action: "找到护照，翻到资料页", doneWhen: "能看到到期日期", role: .preparation),
                    HoloTaskExecutionManualStep(action: "找到到期日期", doneWhen: "日期已读出", role: .execution),
                    HoloTaskExecutionManualStep(action: "把日期记到任务备注", doneWhen: "备注里出现日期", role: .verification, coversRequirementIDs: ["req-1"]),
                ],
                originMatterID: nil,
                acceptedSource: .manual,
                operationID: "op-adopt-\(task.id.uuidString)",
                sourceSurface: "test"
            ),
            in: repo
        )
    }

    // MARK: - E01 采纳不新增任务

    func test_E01_采纳分步计划_不新增TodoTask() throws {
        let (repo, ctx, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对并记录护照有效期")
        _ = try adoptThreeStepPlan(repo, service, execRepo, task: task)

        let allTasks = try ctx.fetch(TodoTask.fetchRequest())
        XCTAssertEqual(allTasks.count, 1, "拆解不得生成第二套待办")
        XCTAssertEqual(task.executionSchemaVersion, 1)
        XCTAssertNotNil(task.activeExecutionRevisionID)
    }

    // MARK: - E03 幂等采纳

    func test_E03_同operationID重复采纳_只生成一份版本() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        _ = try adoptThreeStepPlan(repo, service, execRepo, task: task)

        let duplicateOperationID = "op-adopt-\(task.id.uuidString)"
        let again = try service.adopt(
            HoloTaskExecutionService.AdoptionInput(
                taskID: task.id,
                expectedFingerprint: try snapshotFingerprint(execRepo, taskID: task.id),
                outcomeSummary: "重复采纳",
                verificationPrompt: "重复",
                requirements: [],
                steps: [HoloTaskExecutionManualStep(action: "重复步骤", doneWhen: "重复")],
                originMatterID: nil,
                acceptedSource: .manual,
                operationID: duplicateOperationID,
                sourceSurface: "test"
            ),
            in: repo
        )
        // 返回既有版本，不产生第二份
        let steps = execRepo.steps(taskID: task.id)
        XCTAssertEqual(steps.count, 3, "重放不得生成第二份版本或新节点")
        XCTAssertEqual(again.taskID, task.id)
    }

    // MARK: - E04/E05 推进不误完成

    func test_E04_完成准备步骤_根任务不完成() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let firstStepID = try XCTUnwrap(view.currentStepID)

        try service.completeStep(
            stepID: firstStepID, revisionID: revision.id,
            expectedStateVersion: 1, operationID: "op-e04", sourceSurface: "test",
            in: repo
        )

        XCTAssertFalse(task.completed, "准备完成 ≠ 结果完成")
        XCTAssertNil(task.completedAt)
        // 已完成 1 步的轻量文字回执由 UI 层呈现；此处只验业务事实
        let after = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertEqual(after.state, .ready)
    }

    func test_E05_全部必要步骤完成_readyToConfirm_不自动完成根() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        for stepID in view.resolution?.actionableIDs ?? [] {
            try service.completeStep(
                stepID: stepID, revisionID: revision.id,
                expectedStateVersion: 1, operationID: "op-e05-\(stepID.uuidString)", sourceSurface: "test",
                in: repo
            )
        }

        let after = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertEqual(after.state, .readyToConfirm)
        XCTAssertFalse(task.completed, "步骤全做完只进入可确认，不推出完成")
    }

    // MARK: - E06 合并确认原子提交

    func test_E06_最后一步加根任务同一提交() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let all = view.resolution?.actionableIDs ?? []
        for stepID in all.dropLast() {
            try service.completeStep(
                stepID: stepID, revisionID: revision.id,
                expectedStateVersion: 1, operationID: "op-e06-\(stepID.uuidString)", sourceSurface: "test",
                in: repo
            )
        }
        let finalStepID = try XCTUnwrap(all.last)

        try service.requestCompleteOutcome(
            taskID: task.id, revisionID: revision.id,
            finalStepID: finalStepID, finalStepExpectedStateVersion: 1,
            userAssertion: "已记录并核对", operationID: "op-e06-final", sourceSurface: "test",
            in: repo
        )

        XCTAssertTrue(task.completed)
        let finalStep = try XCTUnwrap(execRepo.step(id: finalStepID, taskID: task.id))
        XCTAssertEqual(finalStep.state, .done)
        XCTAssertNotNil(execRepo.receipt(operationID: "op-e06-final"), "根完成回执必写")
        XCTAssertNotNil(execRepo.receipt(operationID: "op-e06-final-step"), "最终步骤回执必写")
    }

    // MARK: - E10 直接完成不补勾步骤

    func test_E10_根直接完成_未做步骤不被补勾() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)

        try service.completeRootDirectly(
            taskID: task.id, sourceSurface: "test.direct", operationID: "op-e10", in: repo
        )

        XCTAssertTrue(task.completed)
        for step in execRepo.steps(taskID: task.id) {
            XCTAssertEqual(step.state, .pending, "跳过的步骤保留未执行历史，不被伪造成已做")
        }
        XCTAssertNotNil(execRepo.receipt(operationID: "op-e10"))
    }

    // MARK: - E11 根重开保留步骤历史

    func test_E11_根重新打开_步骤历史保留() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let firstStepID = try XCTUnwrap(view.currentStepID)
        try service.completeStep(
            stepID: firstStepID, revisionID: revision.id,
            expectedStateVersion: 1, operationID: "op-e11-step", sourceSurface: "test", in: repo
        )
        try service.completeRootDirectly(taskID: task.id, sourceSurface: "test", operationID: "op-e11-root", in: repo)

        // 重新打开根任务（沿用原流程）
        try repo.toggleTaskCompletion(task)

        XCTAssertFalse(task.completed)
        let step = try XCTUnwrap(execRepo.step(id: firstStepID, taskID: task.id))
        XCTAssertEqual(step.state, .done, "重新打开不清理真实步骤历史")
    }

    // MARK: - E12 根完成后重开必要步骤 → 原子重开根

    func test_E12_根完成后重开步骤_根原子重开() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let firstStepID = try XCTUnwrap(view.resolution?.actionableIDs.first)
        // 全部步骤做完 → 结果确认（步骤与根都完成）
        for stepID in view.resolution?.actionableIDs ?? [] {
            try service.completeStep(
                stepID: stepID, revisionID: revision.id,
                expectedStateVersion: 1, operationID: "op-e12-\(stepID.uuidString)", sourceSurface: "test", in: repo
            )
        }
        try service.requestCompleteOutcome(
            taskID: task.id, revisionID: revision.id,
            finalStepID: nil, finalStepExpectedStateVersion: nil,
            userAssertion: "已完成并核对", operationID: "op-e12-root", sourceSurface: "test",
            in: repo
        )
        XCTAssertTrue(task.completed)

        // 重开已完成内部步骤：同一事务重开根（规格 §8.3）
        try service.reopenStep(
            stepID: firstStepID, revisionID: revision.id,
            expectedStateVersion: 2, operationID: "op-e12-reopen", sourceSurface: "test", in: repo
        )

        let step = try XCTUnwrap(execRepo.step(id: firstStepID, taskID: task.id))
        XCTAssertEqual(step.state, .pending)
        XCTAssertFalse(task.completed, "重开必要步骤必须同事务重开根，不允许根仍完成的无提示矛盾")
        XCTAssertNotNil(execRepo.receipt(operationID: "op-e12-reopen"))
        XCTAssertNotNil(execRepo.receipt(operationID: "op-e12-reopen-root"))
    }

    // MARK: - E13 撤回上游不删下游历史

    func test_E13_撤回上游步骤_下游已完成记录保留() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let ids = view.resolution?.actionableIDs ?? []
        let firstID = try XCTUnwrap(ids.first)
        let secondID = try XCTUnwrap(ids.dropFirst().first)
        try service.completeStep(stepID: firstID, revisionID: revision.id, expectedStateVersion: 1, operationID: "op-e13-1", sourceSurface: "test", in: repo)
        try service.completeStep(stepID: secondID, revisionID: revision.id, expectedStateVersion: 1, operationID: "op-e13-2", sourceSurface: "test", in: repo)

        try service.reopenStep(stepID: firstID, revisionID: revision.id, expectedStateVersion: 2, operationID: "op-e13-reopen", sourceSurface: "test", in: repo)

        let first = try XCTUnwrap(execRepo.step(id: firstID, taskID: task.id))
        let second = try XCTUnwrap(execRepo.step(id: secondID, taskID: task.id))
        XCTAssertEqual(first.state, .pending)
        XCTAssertEqual(second.state, .done, "后续已发生的真实完成不能被系统假装从未发生")
        XCTAssertNotNil(second.completedAt)
    }

    // MARK: - E14 清单引用节点读同一真实源

    func test_E14_清单引用节点_读取真实CheckItem状态() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "提交报销", checkItemTitles: ["收集发票", "填写报销单"])
        let fingerprint = try snapshotFingerprint(execRepo, taskID: task.id)
        _ = try service.adopt(
            HoloTaskExecutionService.AdoptionInput(
                taskID: task.id,
                expectedFingerprint: fingerprint,
                outcomeSummary: "报销系统显示提交成功",
                verificationPrompt: "系统里看到提交成功了吗？",
                requirements: [HoloTaskExecutionRequirement(id: "req-1", content: "提交成功", source: .userStated)],
                steps: [
                    HoloTaskExecutionManualStep(action: "列出缺的发票", doneWhen: "缺票清单写好", role: .preparation),
                    HoloTaskExecutionManualStep(action: "在系统完成填报", doneWhen: "看到提交成功", role: .verification, coversRequirementIDs: ["req-1"]),
                ],
                originMatterID: nil,
                acceptedSource: .manual,
                operationID: "op-e14",
                sourceSurface: "test"
            ),
            in: repo
        )

        // 两个未完成清单项 → 自动出现引用节点（收尾节点，规格 §3.4）
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let topology = try XCTUnwrap(view.topology)
        let referenceNodes = topology.nodes.filter { $0.kind == .sourceCheckItemReference }
        XCTAssertEqual(referenceNodes.count, 2, "每个未完成清单项必须被交代")

        // 勾选真实清单项 → 引用节点派生完成，不维护第二份布尔值
        let item = try XCTUnwrap(view.checklist.first { $0.title == "收集发票" })
        try repo.toggleCheckItem(item)
        let after = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let refState = after.resolution?.states[referenceNodes[0].id]
        XCTAssertEqual(refState, item.id == referenceNodes[0].sourceCheckItemID ? .done : .pending)
    }

    // MARK: - E15/E16 清单级联策略

    func test_E15_分步任务清单全勾不隐式完成根() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "提交报销", checkItemTitles: ["收集发票", "填写报销单"])
        _ = try adoptThreeStepPlan(repo, service, execRepo, task: task)

        XCTAssertFalse(task.allowsChecklistAutoCompletion, "分步接管任务的级联策略由 schema 固定关闭")
        XCTAssertFalse(task.completed)
    }

    func test_E16_普通任务级联策略不变() throws {
        let (repo, _, _, _) = try makeStack()
        let task = try repo.createTask(title: "普通任务", checkItemTitles: ["子项A"])
        XCTAssertTrue(task.allowsChecklistAutoCompletion)
        XCTAssertEqual(task.executionSchemaVersion, 0)
    }

    // MARK: - E19 非法提案拒绝（本地 revise 通道）

    func test_E19_依赖自指_改写缺完成条件_被拒绝() async throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let targetID = try XCTUnwrap(view.currentStepID)
        let fingerprint = try snapshotFingerprint(execRepo, taskID: task.id)

        // 缺完成条件
        let missingDoneWhen = HoloTaskExecutionProposal(
            kind: "proposal",
            outcomeSummary: "同",
            verificationPrompt: "同",
            patch: HoloTaskExecutionProposalPatch(
                mode: .reviseLeaf, targetStepID: targetID,
                newSteps: [HoloTaskExecutionNewStep(ref: "s1", action: "改写", doneWhen: "", dependsOnRefs: [], coversRequirementIDs: [])],
                retainedStepIDs: [], retainTarget: true, requirements: nil
            ),
            scopeChanges: []
        )
        XCTAssertThrowsError(try service.revisePlan(
            taskID: task.id, proposal: missingDoneWhen,
            expectedFingerprint: fingerprint, operationID: "op-e19a", sourceSurface: "test", in: repo
        ))

        // prep 不保留义务
        let noRetain = HoloTaskExecutionProposal(
            kind: "proposal",
            outcomeSummary: "同",
            verificationPrompt: "同",
            patch: HoloTaskExecutionProposalPatch(
                mode: .prependPreparation, targetStepID: targetID,
                newSteps: [HoloTaskExecutionNewStep(ref: "p1", action: "只准备", doneWhen: "准备完", dependsOnRefs: [], coversRequirementIDs: [])],
                retainedStepIDs: [], retainTarget: false, requirements: nil
            ),
            scopeChanges: []
        )
        XCTAssertThrowsError(try service.revisePlan(
            taskID: task.id, proposal: noRetain,
            expectedFingerprint: fingerprint, operationID: "op-e19b", sourceSurface: "test", in: repo
        ))
        XCTAssertNotNil(execRepo.revision(id: revision.id), "拒绝后原计划仍在")
    }

    func test_E19b_依赖循环在拓扑构建时被拒绝() {
        // 循环：a→b→a
        let a = UUID(), b = UUID()
        let topology = HoloTaskExecutionTopology(nodes: [
            HoloTaskExecutionTopologyNode(id: a, kindRaw: "action", stableOrder: 0, required: true, dependsOn: [b], coversRequirementIDs: [], parentGroupID: nil, sourceCheckItemID: nil, roleRaw: nil),
            HoloTaskExecutionTopologyNode(id: b, kindRaw: "action", stableOrder: 1, required: true, dependsOn: [a], coversRequirementIDs: [], parentGroupID: nil, sourceCheckItemID: nil, roleRaw: nil),
        ])
        XCTAssertNotNil(HoloTaskExecutionPolicy.detectCycle(topology))
    }

    // MARK: - E20 迟到候选

    func test_E20_源指纹过期_采纳被拒() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let staleFingerprint = try snapshotFingerprint(execRepo, taskID: task.id)

        // 指纹建立后任务改了标题
        try repo.updateTask(task, title: "核对并记录护照有效期")

        XCTAssertThrowsError(try adoptThreeStepPlan(repo, service, execRepo, task: task, fingerprint: staleFingerprint)) { error in
            XCTAssertEqual(error as? HoloTaskExecutionError, .sourceStale)
        }
    }

    // MARK: - E41/E42 指纹分离

    func test_E41_勾步骤让候选过期_但契约不失效() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let firstStepID = try XCTUnwrap(view.currentStepID)
        try service.completeStep(
            stepID: firstStepID, revisionID: revision.id,
            expectedStateVersion: 1, operationID: "op-e41", sourceSurface: "test", in: repo
        )

        let after = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertTrue(after.contractValid, "勾一步不得让已采纳契约进入复核")
        // 候选快照指纹已变化（迟到候选会被拒）
        let current = try snapshotFingerprint(execRepo, taskID: task.id)
        XCTAssertNotEqual(current, revision.sourceFingerprint)
    }

    func test_E42_改结果描述_契约进入复核() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        _ = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        XCTAssertTrue(try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil)).contractValid)

        try repo.updateTask(task, title: "核对并记录全家人护照有效期")

        let after = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertFalse(after.contractValid, "结果义务相关内容变化必须触发复核")
        XCTAssertEqual(after.state, .needsReview)
    }

    // MARK: - 等待与恢复（规格 §4.5）

    func test_等待后无可做_恢复后可做() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "提交报销")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let currentID = try XCTUnwrap(view.currentStepID)

        // 三个步骤互为并行：全部转入等待后无可做（并行步骤不被制造成强依赖）
        for stepID in view.resolution?.actionableIDs ?? [] {
            try service.setWaiting(
                stepID: stepID, revisionID: revision.id, expectedStateVersion: 1,
                reason: "等同事发票", reviewAfter: nil,
                operationID: "op-wait-\(stepID.uuidString)", sourceSurface: "test", in: repo
            )
        }

        XCTAssertNil(execRepo.executionView(taskID: task.id, cursorStepID: nil)?.currentStepID)
        let waitingView = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertEqual(waitingView.waitingSteps.count, 3)
        XCTAssertEqual(waitingView.waitingSteps.first?.waitReason, "等同事发票")
        // 等待不被记为完成
        let waitingStep = try XCTUnwrap(execRepo.step(id: currentID, taskID: task.id))
        XCTAssertNil(waitingStep.completedAt)

        try service.resumeStep(
            stepID: currentID, revisionID: revision.id, expectedStateVersion: 2,
            operationID: "op-resume", sourceSurface: "test", in: repo
        )
        let resumed = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        XCTAssertEqual(resumed.currentStepID, currentID)
    }

    // MARK: - 并发保护（规格 §8.3）

    func test_状态版本不匹配_拒绝并保留原状态() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let stepID = try XCTUnwrap(view.currentStepID)

        XCTAssertThrowsError(try service.completeStep(
            stepID: stepID, revisionID: revision.id,
            expectedStateVersion: 99, operationID: "op-stale", sourceSurface: "test", in: repo
        )) { error in
            guard case HoloTaskExecutionError.stateVersionMismatch = error else {
                return XCTFail("应报状态版本不匹配，实际 \(error)")
            }
        }
        XCTAssertEqual(execRepo.step(id: stepID, taskID: task.id)?.state, .pending)
    }

    // MARK: - 依赖与等待状态门禁

    func test_等待中的步骤不能直接完成() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "提交报销")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let stepID = try XCTUnwrap(view.currentStepID)
        try service.setWaiting(stepID: stepID, revisionID: revision.id, expectedStateVersion: 1, reason: "等资料", reviewAfter: nil, operationID: "op-w2", sourceSurface: "test", in: repo)

        XCTAssertThrowsError(try service.completeStep(
            stepID: stepID, revisionID: revision.id,
            expectedStateVersion: 2, operationID: "op-w3", sourceSurface: "test", in: repo
        )) { error in
            XCTAssertEqual(error as? HoloTaskExecutionError, .stepWaiting)
        }
    }

    // MARK: - 上限（规格 §5.5）

    func test_超过初始叶子上限_拒绝采纳() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "大任务")
        let fingerprint = try snapshotFingerprint(execRepo, taskID: task.id)
        let tooMany = (0..<8).map { i in
            HoloTaskExecutionManualStep(action: "步骤\(i)", doneWhen: "条件\(i)", role: .execution)
        }
        XCTAssertThrowsError(try service.adopt(
            HoloTaskExecutionService.AdoptionInput(
                taskID: task.id, expectedFingerprint: fingerprint,
                outcomeSummary: "结果", verificationPrompt: "确认",
                requirements: [HoloTaskExecutionRequirement(id: "req-1", content: "完成", source: .userStated)],
                steps: tooMany, originMatterID: nil, acceptedSource: .manual,
                operationID: "op-limit", sourceSurface: "test"
            ),
            in: repo
        )) { error in
            guard case HoloTaskExecutionError.limitsExceeded = error else {
                return XCTFail("应报上限超限，实际 \(error)")
            }
        }
        XCTAssertEqual(task.executionSchemaVersion, 0, "失败采纳不留半个状态")
    }

    // MARK: - 停留记录（规格 §4.6）

    func test_保存停留记录() throws {
        let (repo, _, service, execRepo) = try makeStack()
        let task = try repo.createTask(title: "核对护照")
        let revision = try adoptThreeStepPlan(repo, service, execRepo, task: task)
        let view = try XCTUnwrap(execRepo.executionView(taskID: task.id, cursorStepID: nil))
        let stepID = try XCTUnwrap(view.currentStepID)

        try service.saveResumeNote(
            stepID: stepID, note: "护照在书包外袋", revisionID: revision.id,
            operationID: "op-note", sourceSurface: "test", in: repo
        )
        XCTAssertEqual(execRepo.step(id: stepID, taskID: task.id)?.userResumeNote, "护照在书包外袋")
    }
}
