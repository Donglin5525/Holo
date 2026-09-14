//
//  HoloMatterTaskLinkingTests.swift
//  HoloTests
//
//  任务与 Matter 补链 + 类型化任务变更协调（今日看板 Matter 化方案 §8.3/§8.4/§13.2）
//
//  覆盖：创建后即时链接、激活后按回执补链（两种顺序均闭环）、link 幂等、
//  任务变更驱动 Matter revision/投影、无关任务零成本、同变更幂等。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloMatterTaskLinkingTests: XCTestCase {

    private static let container: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "MatterTaskLinkingTests", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!
    private var todoRepo: TodoRepository!

    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() async throws {
        context = Self.container.viewContext
        for entityName in ["HoloMatter", "HoloMatterOpenLoop", "HoloMatterLink", "HoloMatterEvent", "TodoTask", "TodoList"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in (try? context.fetch(request)) ?? [] {
                context.delete(object)
            }
        }
        try? context.save()
        repo = HoloMatterRepository(context: context, clock: { [weak self] in self?.fixedNow ?? Date() })
        todoRepo = TodoRepository(context: context)
        CoreDataTestSupport.retain(repo, todoRepo)
    }

    /// 激活一件 Matter（同 HoloMatterRepositoryTests 范式）。
    private func activateMatter(messageID: UUID) async throws -> UUID {
        let draft = HoloContextPlanDraft(
            runID: "run-1", draftRevision: 1,
            goalSummary: "国庆日本旅行准备", answerText: "回答",
            items: [],
            unknowns: [HoloContextPlanUnknown(question: "猫咪由谁照顾", impact: "影响安排", independentParts: "")]
        )
        let receipt = try await repo.activateMatter(request: HoloMatterActivationRequest(
            draft: draft,
            contextPlanMessageID: messageID,
            confirmedTitle: "国庆日本旅行",
            confirmedTargetDate: nil
        ))
        return receipt.matterID
    }

    /// 走真实 TodoRepository 创建任务并写入来源字段。
    private func createTask(messageID: UUID, title: String = "确认签证材料") throws -> TodoTask {
        let task = try todoRepo.createTask(title: title, dueDate: nil)
        todoRepo.markTaskAISource(taskId: task.id, messageId: messageID.uuidString, itemId: "item-1")
        return task
    }

    // MARK: - 任务先创建、Matter 后激活 → 激活时按回执补链

    func test_激活后按来源回执补链既有任务() async throws {
        let messageID = UUID()
        let task = try createTask(messageID: messageID)
        let matterID = try await activateMatter(messageID: messageID)

        let linked = try await HoloMatterLinkingCoordinator.linkExistingTasksFromReceipts(
            matterID: matterID,
            contextPlanMessageID: messageID,
            taskFinder: { id in self.todoRepo.findTask(by: id) },
            aiSourceFinder: { messageID, itemID in
                self.todoRepo.findTaskByAISource(messageId: messageID, itemId: itemID)
            },
            receipts: [
                "run-1|item-1": HoloContextPlanTaskReceiptV2(
                    logicalItemID: "run-1|item-1",
                    fingerprint: "fp",
                    taskID: task.id,
                    sourceMessageID: messageID,
                    sourceItemID: "item-1",
                    createdAt: fixedNow
                )
            ],
            repository: repo
        )
        XCTAssertTrue(linked.contains(task.id), "既有任务应在激活时补链")

        let links = repo.links(matterID: matterID)
        XCTAssertEqual(
            links.filter { $0.entityType == .todoTask && $0.entityID == task.id.uuidString }.count,
            1,
            "任务链接真实存在"
        )
    }

    /// legacy 回执（无 taskID）不得伪造链接。
    func test_legacy回执不伪造链接() async throws {
        let messageID = UUID()
        let matterID = try await activateMatter(messageID: messageID)

        let linked = try await HoloMatterLinkingCoordinator.linkExistingTasksFromReceipts(
            matterID: matterID,
            contextPlanMessageID: messageID,
            taskFinder: { _ in nil },
            aiSourceFinder: { _, _ in nil },
            receipts: [
                "run-1|item-1": HoloContextPlanTaskReceiptV2(
                    logicalItemID: "run-1|item-1",
                    fingerprint: "legacy-fp",
                    taskID: nil, // legacy
                    sourceMessageID: nil,
                    sourceItemID: "item-1",
                    createdAt: fixedNow
                )
            ],
            repository: repo
        )
        XCTAssertTrue(linked.isEmpty, "legacy 回执缺 taskID，禁止补链")
        XCTAssertTrue(repo.links(matterID: matterID).filter { $0.entityType == .todoTask }.isEmpty)
    }

    // MARK: - link 幂等

    func test_重复补链幂等不产生副本() async throws {
        let messageID = UUID()
        let task = try createTask(messageID: messageID)
        let matterID = try await activateMatter(messageID: messageID)

        _ = try await repo.addLink(
            matterID: matterID, entityType: .todoTask,
            entityID: task.id.uuidString, role: .action, origin: .system
        )
        let revisionBefore = repo.matter(id: matterID)?.revision

        _ = try await repo.addLink(
            matterID: matterID, entityType: .todoTask,
            entityID: task.id.uuidString, role: .action, origin: .system
        )
        let links = repo.links(matterID: matterID).filter { $0.entityType == .todoTask }
        XCTAssertEqual(links.count, 1, "同 matter+type+entity 重复链接折叠为一行")
        XCTAssertEqual(repo.matter(id: matterID)?.revision, revisionBefore, "幂等折叠不再 bump revision")
    }

    // MARK: - 类型化任务变更 → Matter 投影联动

    func test_完成任务触发关联Matter投影重建() async throws {
        let messageID = UUID()
        let task = try createTask(messageID: messageID)
        let matterID = try await activateMatter(messageID: messageID)
        _ = try await repo.addLink(
            matterID: matterID, entityType: .todoTask,
            entityID: task.id.uuidString, role: .action, origin: .system
        )
        try await refreshProjection(matterID: matterID)

        let revisionBefore = repo.matter(id: matterID)?.revision

        let coordinator = HoloMatterLinkedEntityChangeCoordinator(repository: repo)
        try await coordinator.handleTaskChange(HoloTaskChange(
            taskID: task.id,
            changeKind: .completed,
            changedAt: fixedNow.addingTimeInterval(60)
        ))

        let matter = repo.matter(id: matterID)
        XCTAssertEqual(matter?.revision, (revisionBefore ?? 0) + 1, "linked task 完成必须 bump Matter revision")
        // 同一 taskID+updatedAt+changeKind 重复投递只处理一次。
        try await coordinator.handleTaskChange(HoloTaskChange(
            taskID: task.id,
            changeKind: .completed,
            changedAt: fixedNow.addingTimeInterval(60)
        ))
        XCTAssertEqual(repo.matter(id: matterID)?.revision, (revisionBefore ?? 0) + 1, "重复变更幂等")
    }

    func test_无关联任务变更零成本返回() async throws {
        let messageID = UUID()
        let matterID = try await activateMatter(messageID: messageID)
        try await refreshProjection(matterID: matterID)
        let revisionBefore = repo.matter(id: matterID)?.revision

        let unrelated = try todoRepo.createTask(title: "买牛奶")
        let coordinator = HoloMatterLinkedEntityChangeCoordinator(repository: repo)
        try await coordinator.handleTaskChange(HoloTaskChange(
            taskID: unrelated.id, changeKind: .completed, changedAt: fixedNow
        ))
        XCTAssertEqual(repo.matter(id: matterID)?.revision, revisionBefore, "无关任务不触碰 Matter")
    }

    /// Open Loop 建任务后（同标题 confirmed loop 存在时）nextAction 从 loop 升级为真实任务。
    func test_任务创建后nextAction解析为真实任务() async throws {
        let messageID = UUID()
        let task = try createTask(messageID: messageID, title: "确认签证材料")
        let matterID = try await activateMatter(messageID: messageID)
        // 用户把建议升级为确认（模拟确认签证材料是已确认 loop）
        let loops = repo.openLoops(matterID: matterID)
        XCTAssertFalse(loops.isEmpty)
        try await repo.addLink(
            matterID: matterID, entityType: .todoTask,
            entityID: task.id.uuidString, role: .action, origin: .system
        )

        let linkedTasks = repo.links(matterID: matterID)
            .filter { $0.entityType == .todoTask && $0.isLinked }
        let resolved = linkedTasks.compactMap { UUID(uuidString: $0.entityID) }
        XCTAssertTrue(resolved.contains(task.id), "统一动作解析按真实 taskID 找到任务")
    }

    // MARK: - ProjectionBuilder Next Action 真目标

    func test_projectionNextAction带真实loopID() {
        let loopID = UUID()
        let loop = HoloMatterAttentionPolicy.LoopInput(
            id: loopID,
            title: "确认签证材料",
            state: .open, epistemic: .confirmed,
            targetDate: fixedNow.addingTimeInterval(-86400)
        )
        let next = HoloMatterProjectionBuilder.selectNextAction(loops: [loop], now: fixedNow)
        XCTAssertEqual(next?.kind, .openLoopAction)
        XCTAssertEqual(next?.entityID, loopID.uuidString, "openLoopAction 必须携带真实 loop entityID")
    }

    func test_projectionNextAction指向已链接任务时升级linkedTask() {
        let taskID = UUID()
        let loop = HoloMatterAttentionPolicy.LoopInput(
            id: UUID(), title: "确认签证材料",
            state: .open, epistemic: .confirmed,
            targetDate: nil,
            linkedTaskID: taskID
        )
        let next = HoloMatterProjectionBuilder.selectNextAction(loops: [loop], now: fixedNow)
        XCTAssertEqual(next?.kind, .linkedTask, "loop 已链接任务时 next action 升级为 linkedTask")
        XCTAssertEqual(next?.entityID, taskID.uuidString)
    }

    // MARK: - Helpers

    private func refreshProjection(matterID: UUID) async throws {
        guard let matter = repo.matter(id: matterID) else { return }
        let loops = repo.openLoops(matterID: matterID).map {
            HoloMatterAttentionPolicy.LoopInput(
                title: $0.title, state: $0.state, epistemic: $0.epistemic, targetDate: $0.targetDate
            )
        }
        let snapshot = HoloMatterProjectionBuilder.MatterSnapshot(
            matterID: matter.id, title: matter.title,
            revision: matter.revision, targetDate: matter.targetDate, phase: matter.phase
        )
        try await repo.saveProjection(
            matterID: matterID,
            projection: HoloMatterProjectionBuilder.buildDeterministic(from: snapshot, loops: loops, now: fixedNow)
        )
    }
}

/// 管道辅助（保持 createTask 表达紧凑）。
