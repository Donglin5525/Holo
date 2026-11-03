//
//  TodoListEphemeralTests.swift
//  HoloTests
//
//  一次性清单退场机制单测（2026-10-11）
//
//  覆盖：reconcile 退场扫描各分支（全完成/有未完成/长期/宽限期/空清单）、
//  创建来源赋值（AI 归组新建标一次性、匹配已有不改）、恢复即转正、
//  存量迁移口径（做完的收/有任务不收/空清单不收）、completeTask 端到端收口
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class TodoListEphemeralTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: TodoRepository!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearAllEntities(context)
        repo = TodoRepository(context: context)
    }

    // MARK: - 构造

    /// 造清单；createdMinutesAgo 传 nil 表示现在创建（宽限期内），传分钟数则回拨
    @discardableResult
    private func makeList(
        name: String,
        isEphemeral: Bool,
        archived: Bool = false,
        createdMinutesAgo: Double? = 60
    ) throws -> TodoList {
        let list = TodoList.create(in: context, name: name, isEphemeral: isEphemeral)
        if let minutes = createdMinutesAgo {
            list.createdAt = Date().addingTimeInterval(-minutes * 60)
        }
        list.archived = archived
        try context.save()
        return list
    }

    @discardableResult
    private func makeTask(
        in list: TodoList,
        title: String = "任务",
        completed: Bool = false
    ) throws -> TodoTask {
        let task = try repo.createTask(title: title, list: list)
        if completed {
            task.completed = true
            task.completedAt = Date()
            try context.save()
        }
        return task
    }

    // MARK: - reconcile 退场扫描

    func test_一次性清单全完成_自动归档() throws {
        let list = try makeList(name: "小房间收拾", isEphemeral: true)
        try makeTask(in: list, title: "桌面", completed: true)
        try makeTask(in: list, title: "地面", completed: true)

        let retired = repo.reconcileEphemeralLists()

        XCTAssertEqual(retired, 1)
        XCTAssertTrue(list.archived, "做完的一次性清单应被自动归档")
    }

    func test_一次性清单还有未完成任务_不动() throws {
        let list = try makeList(name: "2026东京", isEphemeral: true)
        try makeTask(in: list, title: "订机票", completed: true)
        try makeTask(in: list, title: "订酒店")

        let retired = repo.reconcileEphemeralLists()

        XCTAssertEqual(retired, 0)
        XCTAssertFalse(list.archived)
    }

    func test_长期清单全完成_绝不自动归档() throws {
        let list = try makeList(name: "工作", isEphemeral: false)
        try makeTask(in: list, title: "周报", completed: true)

        let retired = repo.reconcileEphemeralLists()

        XCTAssertEqual(retired, 0)
        XCTAssertFalse(list.archived, "手建的长期清单哪怕全做完也只许手动归档")
    }

    func test_新建十分钟内的一次性清单_宽限不收() throws {
        // AI 归组是「先建空清单、随后建任务」两步，宽限期内不收
        let list = try makeList(name: "刚建的归组", isEphemeral: true, createdMinutesAgo: nil)

        let retired = repo.reconcileEphemeralLists()

        XCTAssertEqual(retired, 0)
        XCTAssertFalse(list.archived)
    }

    func test_老的一次性空清单_照收() throws {
        let list = try makeList(name: "任务没建成的归组", isEphemeral: true, createdMinutesAgo: 60)

        let retired = repo.reconcileEphemeralLists()

        XCTAssertEqual(retired, 1)
        XCTAssertTrue(list.archived)
    }

    // MARK: - 创建来源赋值

    func test_AI归组新建清单_默认一次性() throws {
        let outcome = try repo.matchOrCreateList(named: "东京旅行")

        XCTAssertEqual(outcome?.created, true)
        XCTAssertEqual(outcome?.list.isEphemeral, true)
    }

    func test_AI归组匹配已有长期清单_不改其类型() throws {
        let existing = try makeList(name: "工作", isEphemeral: false)

        let outcome = try repo.matchOrCreateList(named: "工作")

        XCTAssertEqual(outcome?.created, false)
        XCTAssertIdentical(outcome?.list, existing)
        XCTAssertEqual(existing.isEphemeral, false, "匹配复用不应改已有清单的一次性标记")
    }

    // MARK: - 恢复即转正

    func test_恢复归档清单_自动转长期() throws {
        let list = try makeList(name: "又活过来的项目", isEphemeral: true, archived: true)

        try repo.unarchiveList(list)

        XCTAssertFalse(list.archived)
        XCTAssertEqual(list.isEphemeral, false, "手动恢复是还要用的信号，应转长期防反复收走")
    }

    // MARK: - 存量迁移口径

    func test_存量迁移_只收做完的不分来源() throws {
        let finished = try makeList(name: "做完的一次性项目", isEphemeral: false)
        try makeTask(in: finished, title: "步骤", completed: true)
        let ongoing = try makeList(name: "还有任务", isEphemeral: false)
        try makeTask(in: ongoing, title: "未完成")
        let neverUsed = try makeList(name: "手建还没用", isEphemeral: false)
        _ = neverUsed
        let alreadyArchived = try makeList(name: "已在归档", isEphemeral: false, archived: true)
        try makeTask(in: alreadyArchived, title: "旧任务", completed: true)

        let archived = try TodoListEphemeralMigration.archiveEmptiedLists(in: context)

        XCTAssertEqual(archived, 1)
        XCTAssertTrue(finished.archived, "有已完成任务且无未完成的存量清单应收")
        XCTAssertFalse(ongoing.archived)
        XCTAssertFalse(neverUsed.archived, "从未有任务的空清单不收（可能是手建未启用）")
        XCTAssertTrue(alreadyArchived.archived, "已归档保持原状")
    }

    // MARK: - 端到端收口

    func test_完成任务经仓库落库_清单自动退场() throws {
        let list = try makeList(name: "收尾项目", isEphemeral: true)
        let task = try makeTask(in: list, title: "最后一步")

        try repo.completeTask(task)

        XCTAssertTrue(task.completed)
        XCTAssertTrue(list.archived, "completeTask → notifyDataChange → reconcile 收口应自动退场")
    }
}
