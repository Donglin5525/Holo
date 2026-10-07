//
//  TodayPlanServiceTests.swift
//  HoloTests
//
//  「今天减负」计划服务事务单测（2026-10-03 实施方案 §8）
//  幂等/原子/撤销/heads 防线/空库创建/期限确认——每测试独立内存容器。
//

import XCTest
import CoreData
@testable import Holo

final class TodayPlanServiceTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var service: HoloTodayPlanService!
    private var repository: HoloTodayPlanRepository!
    private var todoRepo: TodoRepository!

    override func setUpWithError() throws {
        let model = CoreDataTestSupport.sharedModel
        container = NSPersistentContainer(name: "TodayPlanServiceTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        service = HoloTodayPlanService(container: container)
        repository = HoloTodayPlanRepository(context: container.viewContext)
        todoRepo = TodoRepository(context: container.viewContext)
        CoreDataTestSupport.retain(container, service, repository, todoRepo)
    }

    private var scope: HoloTodayDayScope { .current() }

    // MARK: - 基础采用（§8.1）

    func test_采用_写入与读取一致() async throws {
        let task = try todoRepo.createTask(title: "提交活动报名")
        let payload = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [.init(taskID: task.id, goal: .taskResult)]
        )
        let receipt = try await service.adopt(
            candidate: HoloTodayPlanCandidate(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil,
            expectedHeads: [],
            operationID: "op-adopt-1"
        )
        XCTAssertTrue(receipt.changed)
        XCTAssertFalse(receipt.replayed)
        XCTAssertNil(receipt.createdTaskID)

        let read = repository.currentPlan(scope: scope)
        guard case .active(let headPayload, let heads) = read.state else {
            return XCTFail("期望 active，实得 \(read.state)")
        }
        XCTAssertEqual(headPayload, payload)
        XCTAssertEqual(heads, [receipt.revisionID!])

        // 原任务日期未被污染（INV-1）
        XCTAssertEqual(task.dueDate, nil)
    }

    func test_重复采用_幂等同次结果() async throws {
        let task = try todoRepo.createTask(title: "提交活动报名")
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        let candidate = HoloTodayPlanCandidate(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil)

        let first = try await service.adopt(candidate: candidate, editedPayload: nil, expectedHeads: [], operationID: "op-retry")
        let second = try await service.adopt(candidate: candidate, editedPayload: nil, expectedHeads: [], operationID: "op-retry")

        XCTAssertTrue(second.replayed)
        XCTAssertEqual(second.revisionID, first.revisionID)
        XCTAssertEqual(second.payload, first.payload)
        // 只有一条版本（R09）
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        let count = try container.viewContext.count(for: request)
        XCTAssertEqual(count, 1)
    }

    func test_重复采用_同operationID不同digest报冲突() async throws {
        let task = try todoRepo.createTask(title: "提交活动报名")
        let payloadA = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        _ = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payloadA, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [], operationID: "op-digest"
        )
        let payloadB = HoloTodayPlanPayload(selectionMode: .explicit, entries: [], deferredTaskIDs: [task.id])
        do {
            _ = try await service.adopt(
                candidate: .init(scope: scope, sourceFingerprint: "", payload: payloadB, newTaskTitle: nil),
                editedPayload: nil, expectedHeads: [], operationID: "op-digest"
            )
            XCTFail("应报冲突")
        } catch let error as HoloTodayPlanError {
            guard case .conflict = error else { return XCTFail("期望 conflict，实得 \(error)") }
        }
    }

    func test_heads防线_过期heads拒绝() async throws {
        let task = try todoRepo.createTask(title: "提交活动报名")
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        _ = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [], operationID: "op-heads-1"
        )
        // 期望 heads 仍传 [] → 与实际单 head 不符 → conflict（本机两处并发防线）
        do {
            _ = try await service.addTask(
                taskID: UUID(), goal: .taskResult, scope: scope,
                expectedHeads: [], operationID: "op-heads-2"
            )
            XCTFail("应报 conflict")
        } catch let error as HoloTodayPlanError {
            guard case .conflict = error else { return XCTFail("期望 conflict，实得 \(error)") }
        }
    }

    func test_跨午夜_过期scope拒绝() async throws {
        // 构造昨天的 scope（不含当前时刻）
        var yesterdayCalendar = Calendar(identifier: .gregorian)
        yesterdayCalendar.timeZone = .current
        let yesterday = yesterdayCalendar.date(byAdding: .day, value: -1, to: Date())!
        let staleScope = HoloTodayDayScope(referenceTime: yesterday, calendar: yesterdayCalendar, timeZone: .current)
        do {
            _ = try await service.addTask(
                taskID: UUID(), goal: .taskResult, scope: staleScope,
                expectedHeads: [], operationID: "op-expired"
            )
            XCTFail("应报 expiredDay")
        } catch let error as HoloTodayPlanError {
            guard case .expiredDay = error else { return XCTFail("期望 expiredDay，实得 \(error)") }
        }
    }

    // MARK: - 手动操作（§8.1 首次手动语义）

    func test_手动加入_无计划时以该任务为起点() async throws {
        let task = try todoRepo.createTask(title: "预订旅行机票")
        let receipt = try await service.addTask(
            taskID: task.id, goal: .taskResult, scope: scope,
            expectedHeads: [], operationID: "op-add-1"
        )
        XCTAssertEqual(receipt.payload.entries.map(\.taskID), [task.id])

        // 重复加同一任务同目标 → unchanged，不写版本（§4.3）
        let again = try await service.addTask(
            taskID: task.id, goal: .taskResult, scope: scope,
            expectedHeads: [receipt.revisionID!], operationID: "op-add-2"
        )
        XCTAssertFalse(again.changed)
        XCTAssertEqual(again.revisionID, receipt.revisionID)
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        XCTAssertEqual(try container.viewContext.count(for: request), 1)
    }

    func test_手动放下_无计划时继承基础可灵活任务() async throws {
        // 基础列表：今日到期 + 无日期（可灵活）；逾期不进 entries
        let todayTask = try todoRepo.createTask(title: "今日到期", dueDate: Date().addingTimeInterval(3_600))
        let noDateTask = try todoRepo.createTask(title: "无日期")
        let overdueTask = try todoRepo.createTask(title: "已逾期", dueDate: Date().addingTimeInterval(-86_400 * 3))
        let laterTask = try todoRepo.createTask(title: "明天到期", dueDate: Date().addingTimeInterval(86_400 * 2))

        let receipt = try await service.deferTask(
            taskID: todayTask.id,
            acknowledgement: .init(
                taskID: todayTask.id,
                deadlineFingerprint: HoloTodayReliefPolicy.deadlineFingerprint(dueDate: todayTask.dueDate, isAllDay: todayTask.isAllDay)!
            ),
            scope: scope,
            expectedHeads: [],
            operationID: "op-defer-1"
        )
        let entryIDs = Set(receipt.payload.entries.map(\.taskID))
        XCTAssertEqual(entryIDs, [noDateTask.id], "只继承无日期任务；今日到期目标已被移出")
        XCTAssertTrue(receipt.payload.isDeferred(todayTask.id))
        XCTAssertFalse(receipt.payload.isDeferred(overdueTask.id), "未选任务不写入放下（只有明确放下才记）")
        XCTAssertFalse(entryIDs.contains(laterTask.id), "未来到期不在基础灵活列表")
        XCTAssertFalse(entryIDs.contains(overdueTask.id), "逾期不进 entries（留在约束区）")
    }

    func test_手动放下_今日到期无确认被拒() async throws {
        let dueToday = try todoRepo.createTask(title: "今晚到期", dueDate: Date().addingTimeInterval(3_600))
        do {
            _ = try await service.deferTask(
                taskID: dueToday.id, acknowledgement: nil,
                scope: scope, expectedHeads: [], operationID: "op-defer-ack"
            )
            XCTFail("应要求风险确认")
        } catch let error as HoloTodayPlanError {
            guard case .acknowledgementRequired(let id) = error else { return XCTFail("期望 acknowledgementRequired，实得 \(error)") }
            XCTAssertEqual(id, dueToday.id)
        }
        // 无截止任务直接可放下
        let noDue = try todoRepo.createTask(title: "无截止")
        let receipt = try await service.deferTask(
            taskID: noDue.id, acknowledgement: nil,
            scope: scope, expectedHeads: [], operationID: "op-defer-ack-2"
        )
        XCTAssertTrue(receipt.payload.isDeferred(noDue.id))
    }

    func test_换目标_需要已有选择() async throws {
        let task = try todoRepo.createTask(title: "机票")
        do {
            _ = try await service.changeGoal(
                taskID: task.id, goal: .taskResult, scope: scope,
                expectedHeads: [], operationID: "op-goal-0"
            )
            XCTFail("无选择不可换目标")
        } catch let error as HoloTodayPlanError {
            guard case .invalidTarget = error else { return XCTFail("期望 invalidTarget，实得 \(error)") }
        }
    }

    // MARK: - 引用有效性

    func test_采用_幽灵任务与已完成任务被拒() async throws {
        let ghostPayload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: UUID(), goal: .taskResult)])
        do {
            _ = try await service.adopt(
                candidate: .init(scope: scope, sourceFingerprint: "", payload: ghostPayload, newTaskTitle: nil),
                editedPayload: nil, expectedHeads: [], operationID: "op-ghost"
            )
            XCTFail("幽灵任务应被拒")
        } catch let error as HoloTodayPlanError {
            guard case .invalidTarget = error else { return XCTFail("期望 invalidTarget，实得 \(error)") }
        }

        let done = try todoRepo.createTask(title: "已完成任务")
        try todoRepo.toggleTaskCompletion(done)
        let donePayload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: done.id, goal: .taskResult)])
        do {
            _ = try await service.adopt(
                candidate: .init(scope: scope, sourceFingerprint: "", payload: donePayload, newTaskTitle: nil),
                editedPayload: nil, expectedHeads: [], operationID: "op-done"
            )
            XCTFail("已完成任务应被拒")
        } catch let error as HoloTodayPlanError {
            guard case .invalidTarget = error else { return XCTFail("期望 invalidTarget，实得 \(error)") }
        }
    }

    // MARK: - 空库创建（§8.2）

    func test_空库创建_一个根任务加一个版本_一次落地() async throws {
        let candidate = HoloTodayPlanCandidate(
            scope: scope,
            sourceFingerprint: "",
            payload: HoloTodayPlanPayload(selectionMode: .explicit),
            newTaskTitle: "写明天分享的提纲"
        )
        let receipt = try await service.adopt(
            candidate: candidate, editedPayload: nil,
            expectedHeads: [], operationID: "op-newtask-1"
        )
        XCTAssertNotNil(receipt.createdTaskID)
        XCTAssertEqual(receipt.payload.entries.count, 1)
        XCTAssertEqual(receipt.payload.entries.first?.goal, .taskResult)

        let created = try XCTUnwrap(todoRepo.findTask(by: receipt.createdTaskID!))
        XCTAssertEqual(created.title, "写明天分享的提纲")
        XCTAssertNil(created.dueDate, "不造截止")
        XCTAssertNil(created.list, "不造清单")
        XCTAssertEqual((created.checkItems?.count ?? 0), 0, "不造步骤")

        // 重放同 operationID → 同一个 createdTaskID，不重复建（R36）
        let replay = try await service.adopt(
            candidate: candidate, editedPayload: nil,
            expectedHeads: [], operationID: "op-newtask-1"
        )
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.createdTaskID, receipt.createdTaskID)
        let taskRequest = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        XCTAssertEqual(try container.viewContext.count(for: taskRequest), 1, "空库创建只建一个根任务")
    }

    func test_空库创建_非空库被拒() async throws {
        _ = try todoRepo.createTask(title: "已有任务")
        do {
            _ = try await service.adopt(
                candidate: .init(scope: scope, sourceFingerprint: "", payload: .init(selectionMode: .explicit), newTaskTitle: "新任务"),
                editedPayload: nil, expectedHeads: [], operationID: "op-newtask-2"
            )
            XCTFail("非空库不允许走创建")
        } catch let error as HoloTodayPlanError {
            guard case .invalidTarget = error else { return XCTFail("期望 invalidTarget，实得 \(error)") }
        }
    }

    // MARK: - 撤销（§8.3）

    func test_撤销_首次采用恢复基础状态() async throws {
        let task = try todoRepo.createTask(title: "报名")
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        let adopted = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [], operationID: "op-undo-1"
        )
        let undone = try await service.undo(
            adoptedRevisionID: adopted.revisionID!,
            scope: scope,
            expectedHeads: [adopted.revisionID!],
            operationID: "op-undo-2"
        )
        XCTAssertEqual(undone.payload.selectionMode, .inheritBase)
        // 历史不删除
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        XCTAssertEqual(try container.viewContext.count(for: request), 2)
        // 任务仍在
        XCTAssertNotNil(todoRepo.findTask(by: task.id))
    }

    func test_撤销_空库创建后新任务保留() async throws {
        let receipt = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: .init(selectionMode: .explicit), newTaskTitle: "新任务"),
            editedPayload: nil, expectedHeads: [], operationID: "op-undo-new-1"
        )
        _ = try await service.undo(
            adoptedRevisionID: receipt.revisionID!,
            scope: scope, expectedHeads: [receipt.revisionID!],
            operationID: "op-undo-new-2"
        )
        // 撤销安排只撤销今日选择，不删除用户确认创建的根任务（§8.2）
        XCTAssertNotNil(todoRepo.findTask(by: receipt.createdTaskID!))
        let read = repository.currentPlan(scope: scope)
        guard case .active(let payload, _) = read.state else { return XCTFail("实得 \(read.state)") }
        XCTAssertEqual(payload.selectionMode, .inheritBase)
    }

    func test_撤销_后来又改安排则失效() async throws {
        let taskA = try todoRepo.createTask(title: "A")
        let taskB = try todoRepo.createTask(title: "B")
        let first = try await service.addTask(
            taskID: taskA.id, goal: .taskResult, scope: scope,
            expectedHeads: [], operationID: "op-chain-1"
        )
        // 用户后来又手动调整（加入 B）
        _ = try await service.addTask(
            taskID: taskB.id, goal: .taskResult, scope: scope,
            expectedHeads: [first.revisionID!], operationID: "op-chain-2"
        )
        // 旧回执（first）的撤销失效：heads 已前进
        do {
            _ = try await service.undo(
                adoptedRevisionID: first.revisionID!,
                scope: scope, expectedHeads: [first.revisionID!],
                operationID: "op-chain-3"
            )
            XCTFail("旧撤销应失效")
        } catch let error as HoloTodayPlanError {
            guard case .conflict = error else { return XCTFail("期望 conflict，实得 \(error)") }
        }
    }

    // MARK: - 无变化（§4.3）

    func test_无变化_不写版本() async throws {
        let task = try todoRepo.createTask(title: "报名")
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        let first = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [], operationID: "op-same-1"
        )
        // 相同 payload 再次采用（不同 operationID、正确 heads）→ unchanged
        let receipt = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [first.revisionID!], operationID: "op-same-2"
        )
        XCTAssertFalse(receipt.changed)
        XCTAssertEqual(receipt.revisionID, first.revisionID)
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        XCTAssertEqual(try container.viewContext.count(for: request), 1, "无变化不写版本、不发成功保存回执")
    }

    // MARK: - 读取状态（§8.4）

    func test_读取_从未采用为noPlan() throws {
        let read = repository.currentPlan(scope: scope)
        guard case .noPlan = read.state else { return XCTFail("期望 noPlan，实得 \(read.state)") }
    }

    func test_模块清空语义_计划软删后回基础态_恢复后回来() async throws {
        // R41：清空任务模块时计划辅助实体同批软删 → 读取回基础行为；恢复后计划可用
        let task = try todoRepo.createTask(title: "报名")
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: task.id, goal: .taskResult)])
        _ = try await service.adopt(
            candidate: .init(scope: scope, sourceFingerprint: "", payload: payload, newTaskTitle: nil),
            editedPayload: nil, expectedHeads: [], operationID: "op-recycle-1"
        )
        guard case .active = repository.currentPlan(scope: scope).state else {
            return XCTFail("前置失败：期望 active")
        }

        // 模拟同批软删（performClear 对辅助实体的效果）
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        let batchID = UUID()
        for revision in try container.viewContext.fetch(request) {
            revision.deletedAt = Date()
            revision.deletedBatchId = batchID
        }
        try container.viewContext.save()

        // 软删后：计划读取回 noPlan（继续基础 Today 行为），不是 syncing/unavailable
        let cleared = repository.currentPlan(scope: scope)
        guard case .noPlan = cleared.state else { return XCTFail("清空后期望 noPlan，实得 \(cleared.state)") }

        // 恢复（clearDeletedMark）后：计划回来
        for revision in try container.viewContext.fetch(request) {
            revision.clearDeletedMark()
        }
        try container.viewContext.save()
        let restored = repository.currentPlan(scope: scope)
        guard case .active(let payload, _) = restored.state else { return XCTFail("恢复后期望 active，实得 \(restored.state)") }
        XCTAssertEqual(payload.entries.first?.taskID, task.id)
    }

    func test_读取_任务行缺失判定syncing不假空() async throws {
        // 场景：CloudKit 先到计划版本、任务引用未到齐
        let taskID = UUID()
        let revision = HoloTodayPlanRevision(context: container.viewContext)
        revision.id = UUID()
        revision.schemaVersion = 1
        revision.scopeKey = scope.scopeKey
        revision.dateKey = scope.dateKey
        revision.timeZoneIdentifier = scope.timeZoneIdentifier
        revision.dayStart = scope.dayStart
        revision.dayEnd = scope.dayEnd
        revision.parentRevisionIDsJSON = "[]"
        revision.operationID = "op-manual-seed"
        revision.commandRaw = HoloTodayPlanCommand.adopt.rawValue
        revision.payloadJSON = String(data: try HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [.init(taskID: taskID, goal: .taskResult)]
        ).canonicalData(), encoding: .utf8)!
        revision.payloadDigest = try HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [.init(taskID: taskID, goal: .taskResult)]
        ).digest()
        revision.createdAt = Date()
        try container.viewContext.save()

        let read = repository.currentPlan(scope: scope)
        guard case .syncing = read.state else { return XCTFail("期望 syncing（引用未到齐不得假空/回退基础），实得 \(read.state)") }
    }

    func test_分叉_双heads判定与解决() async throws {
        // 手工造两条并行 heads（parentIDs 空、互不引用）
        func seed(_ op: String, taskID: UUID) throws {
            let revision = HoloTodayPlanRevision(context: container.viewContext)
            revision.id = UUID()
            revision.schemaVersion = 1
            revision.scopeKey = scope.scopeKey
            revision.dateKey = scope.dateKey
            revision.timeZoneIdentifier = scope.timeZoneIdentifier
            revision.dayStart = scope.dayStart
            revision.dayEnd = scope.dayEnd
            revision.parentRevisionIDsJSON = "[]"
            revision.operationID = op
            revision.commandRaw = HoloTodayPlanCommand.manualAdd.rawValue
            let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: taskID, goal: .taskResult)])
            revision.payloadJSON = String(data: try payload.canonicalData(), encoding: .utf8)!
            revision.payloadDigest = try payload.digest()
            revision.createdAt = Date()
        }
        let taskA = try todoRepo.createTask(title: "A")
        let taskB = try todoRepo.createTask(title: "B")
        try seed("op-fork-a", taskID: taskA.id)
        try seed("op-fork-b", taskID: taskB.id)
        try container.viewContext.save()

        let read = repository.currentPlan(scope: scope)
        guard case .conflict(let candidates) = read.state else { return XCTFail("期望 conflict，实得 \(read.state)") }
        XCTAssertEqual(candidates.count, 2)

        // 用 A 版本解决分叉：resolveConflict 覆盖全部 heads
        let chosen = HoloTodayPlanPayload(selectionMode: .explicit, entries: [.init(taskID: taskA.id, goal: .taskResult)])
        let resolved = try await service.resolveConflict(
            chosenPayload: chosen, scope: scope,
            expectedHeads: candidates.map(\.revisionID),
            operationID: "op-fork-resolve"
        )
        XCTAssertTrue(resolved.changed)
        let after = repository.currentPlan(scope: scope)
        guard case .active(let payload, _) = after.state else { return XCTFail("实得 \(after.state)") }
        XCTAssertEqual(payload.entries.map(\.taskID), [taskA.id])
        // 解决版本的 parentIDs 覆盖两个 heads
        let row = repository.revisions(scopeKey: scope.scopeKey).rows?.first { $0.operationID == "op-fork-resolve" }
        XCTAssertEqual(Set(row?.parentRevisionIDs ?? []), Set(candidates.map(\.revisionID)))
    }
}
