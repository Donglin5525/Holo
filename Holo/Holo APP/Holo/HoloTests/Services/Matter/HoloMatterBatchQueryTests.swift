//
//  HoloMatterBatchQueryTests.swift
//  HoloTests
//
//  事项批量查询与逐个查询的等价性对拍（2026-11-24 技术优化：今日快照由「逐个 Matter 查库」改为批量）。
//  批量版是性能优化，不是行为变更——这里的每一条都把批量结果与原有逐个查询逐项比对。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloMatterBatchQueryTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!

    private let base = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
        repo = HoloMatterRepository(context: context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        repo = nil
        context = nil
        super.tearDown()
    }

    // MARK: - 造数

    private func makeMatter(_ title: String) -> HoloMatter {
        let matter = context.insertTestObject(HoloMatter.self)
        matter.id = UUID()
        matter.schemaVersion = 1
        matter.title = title
        matter.lifecycle = .active
        matter.origin = .manual
        matter.revision = 0
        matter.createdAt = base
        matter.updatedAt = base
        return matter
    }

    private func makeLoop(
        _ matter: HoloMatter, _ title: String,
        state: HoloMatterOpenLoopState, offset: TimeInterval
    ) -> HoloMatterOpenLoop {
        let loop = context.insertTestObject(HoloMatterOpenLoop.self)
        loop.id = UUID()
        loop.matterID = matter.id
        loop.logicalKey = title
        loop.title = title
        loop.state = state
        loop.epistemic = .confirmed
        loop.priority = .normal
        loop.sourceRevision = 0
        loop.revision = 0
        loop.createdAt = base.addingTimeInterval(offset)
        loop.updatedAt = base.addingTimeInterval(offset)
        return loop
    }

    private func makeLink(
        _ matter: HoloMatter, task: TodoTask, role: HoloMatterLinkRole, planOrder: Int16,
        offset: TimeInterval, status: HoloMatterLinkStatus = .linked, sourceRevision: String? = nil
    ) -> HoloMatterLink {
        let link = context.insertTestObject(HoloMatterLink.self)
        link.id = UUID()
        link.matterID = matter.id
        link.entityType = .todoTask
        link.entityID = task.id.uuidString
        link.role = role
        link.origin = .system
        link.confidence = 1
        link.status = status
        link.sourceRevision = sourceRevision
        link.planOrder = planOrder
        link.createdAt = base.addingTimeInterval(offset)
        link.updatedAt = base.addingTimeInterval(offset)
        return link
    }

    private func makeTask(_ title: String, completed: Bool = false, archived: Bool = false, deleted: Bool = false) -> TodoTask {
        let task = context.insertTestObject(TodoTask.self)
        task.id = UUID()
        task.title = title
        task.status = completed ? TaskStatus.completed.rawValue : TaskStatus.todo.rawValue
        task.completed = completed
        task.archived = archived
        task.deletedFlag = deleted
        task.deletedAt = deleted ? base : nil
        task.createdAt = base
        task.updatedAt = base
        return task
    }

    /// LoopInput 不是 Equatable，比对时压成一个字符串
    private func key(_ input: HoloMatterAttentionPolicy.LoopInput) -> String {
        [input.title, input.state.rawValue, input.epistemic.rawValue, input.linkedTaskID?.uuidString ?? "-"].joined(separator: "|")
    }

    /// 排除了归档 / 软删任务、非 action 角色、非 linked 状态后，按 planOrder 再按 id 排序（平级顺序两边都不保证，不比较）。
    private func normalized(_ tasks: [MatterPlanQuery.PlanTask]) -> [MatterPlanQuery.PlanTask] {
        tasks.sorted { ($0.planOrder, $0.id.uuidString) < ($1.planOrder, $1.id.uuidString) }
    }

    // MARK: - 用例

    func test批量与逐个查询结果一致() throws {
        // 两个活跃事项 + 一个软删事项；任务含归档、软删、重复链接、非 action 角色、未生效链接
        let a = makeMatter("东京旅行")
        let b = makeMatter("读完一本书")
        let gone = makeMatter("已删事项")
        gone.deletedAt = base

        let loopA1 = makeLoop(a, "订机票", state: .open, offset: 20)
        let loopA2 = makeLoop(a, "办签证", state: .waiting, offset: 10)
        _ = makeLoop(a, "已解决", state: .resolved, offset: 5)
        let deletedLoop = makeLoop(a, "已删循环", state: .open, offset: 1)
        deletedLoop.deletedAt = base
        _ = makeLoop(b, "选书", state: .open, offset: 30)
        _ = makeLoop(gone, "不该出现", state: .open, offset: 0)

        let t1 = makeTask("核实护照")
        let t2 = makeTask("订住宿", completed: true)
        let archivedTask = makeTask("归档任务", archived: true)
        let deletedTask = makeTask("软删任务", deleted: true)
        _ = makeLink(a, task: t1, role: .action, planOrder: 2, offset: 3, sourceRevision: loopA1.id.uuidString)
        _ = makeLink(a, task: t2, role: .action, planOrder: 1, offset: 2)
        _ = makeLink(a, task: t1, role: .action, planOrder: 0, offset: 4)          // 重复链接：planOrder 取最小
        _ = makeLink(a, task: archivedTask, role: .action, planOrder: 5, offset: 5)
        _ = makeLink(a, task: deletedTask, role: .action, planOrder: 6, offset: 6)
        _ = makeLink(a, task: t2, role: .evidence, planOrder: 7, offset: 7)        // 非 action：不进计划，但算「已链接任务」
        _ = makeLink(a, task: t1, role: .action, planOrder: 8, offset: 8, status: .proposed)   // 未生效：两种查询都不取
        _ = makeLink(b, task: t1, role: .action, planOrder: 0, offset: 9)
        try context.save()

        let ids = [a.id, b.id]

        // 1) open loop：只取活跃（open / waiting），不含软删；组内按 createdAt 升序
        let loopsBatch = repo.openLoops(matterIDs: ids, activeOnly: true)
        for id in ids {
            XCTAssertEqual(loopsBatch[id]?.map(\.id), repo.openLoops(matterID: id, activeOnly: true).map(\.id), "批量与逐个的 open loop 应一致")
        }
        XCTAssertEqual(loopsBatch[a.id]?.map(\.title), ["办签证", "订机票"], "resolved 与软删循环不应出现，且按创建时间升序")
        XCTAssertNil(loopsBatch[gone.id])

        // 2) link：默认只取 linked；linkedOnly: false 时含未生效
        let linksBatch = repo.links(matterIDs: ids)
        let linksBatchAll = repo.links(matterIDs: ids, linkedOnly: false)
        for id in ids {
            XCTAssertEqual(linksBatch[id]?.map(\.id), repo.links(matterID: id).map(\.id))
            XCTAssertEqual(linksBatchAll[id]?.map(\.id), repo.links(matterID: id, linkedOnly: false).map(\.id))
        }
        XCTAssertEqual(linksBatch[a.id]?.count, 6)
        XCTAssertEqual(linksBatchAll[a.id]?.count, 7)

        // 3) attention 输入：循环顺序、状态、loop→task 对应都一致
        let inputsBatch = repo.attentionLoopInputs(matterIDs: ids)
        for id in ids {
            XCTAssertEqual((inputsBatch[id] ?? []).map(key), repo.attentionLoopInputs(matterID: id).map(key), "批量与逐个的 attention 输入应一致")
        }
        XCTAssertEqual((inputsBatch[a.id] ?? []).compactMap(\.linkedTaskID), [t1.id], "只有 sourceRevision 写了 loopID 的那条循环解析出对应任务")

        // 4) 任务批量按 id 查：软删排除，取到的与逐个查是同一个对象
        let tasksBatch = repo.todoTasks(ids: [t1.id, t2.id, archivedTask.id, deletedTask.id, UUID()])
        XCTAssertEqual(Set(tasksBatch.keys), [t1.id, t2.id, archivedTask.id], "软删任务不应取到")
        for (id, task) in tasksBatch {
            XCTAssertTrue(repo.todoTask(id: id) === task, "批量与逐个取到的应是同一个对象")
        }

        // 5) 计划任务：排除归档 / 软删 / 非 action / 未生效，重复链接去重后 planOrder 取最小
        let planBatchA = MatterPlanQuery.planTasks(links: linksBatch[a.id] ?? [], tasks: tasksBatch)
        XCTAssertEqual(normalized(planBatchA), normalized(MatterPlanQuery.planTasks(matterID: a.id, repository: repo)))
        XCTAssertEqual(planBatchA.map(\.title), ["核实护照", "订住宿"], "按 planOrder 升序：核实护照有重复链接，取最小的 0")
        XCTAssertEqual(planBatchA.first?.planOrder, 0)
        XCTAssertEqual(planBatchA.last?.planOrder, 1)
        XCTAssertEqual(
            normalized(MatterPlanQuery.planTasks(links: linksBatch[b.id] ?? [], tasks: tasksBatch)),
            normalized(MatterPlanQuery.planTasks(matterID: b.id, repository: repo))
        )
    }

    func test空输入返回空结果() {
        XCTAssertTrue(repo.openLoops(matterIDs: []).isEmpty)
        XCTAssertTrue(repo.links(matterIDs: []).isEmpty)
        XCTAssertTrue(repo.attentionLoopInputs(matterIDs: []).isEmpty)
        XCTAssertTrue(repo.todoTasks(ids: []).isEmpty)
    }

    func test查不到的事项按空处理() throws {
        let orphan = UUID()
        XCTAssertEqual(repo.attentionLoopInputs(matterIDs: [orphan])[orphan]?.count, 0, "attention 输入对每个传入的事项都有键")
        XCTAssertEqual((repo.links(matterIDs: [orphan])[orphan] ?? []).count, 0, "分组字典对没有行的事项没有键，调用方按空数组处理")
        XCTAssertEqual((repo.openLoops(matterIDs: [orphan])[orphan] ?? []).count, 0)
        XCTAssertEqual(MatterPlanQuery.planTasks(links: repo.links(matterIDs: [orphan])[orphan] ?? [], tasks: [:]).count, 0)
    }
}
