//
//  TodoTaskPlannedTimeRangeTests.swift
//  HoloTests
//
//  任务计划时间段（时间块）字段的约束与读写单测
//

import XCTest
import CoreData
@testable import Holo

final class TodoTaskPlannedTimeRangeTests: XCTestCase {

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "PlannedTimeRangeTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TodoRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    // MARK: - isValidPlannedRange 纯函数

    func test_合法区间_同天且开始早于结束() {
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 12)
        XCTAssertTrue(TodoTask.isValidPlannedRange(start, end))
    }

    func test_非法_跨天() {
        let start = makeDate(2026, 8, 30, hour: 22)
        let end = makeDate(2026, 8, 31, hour: 1)
        XCTAssertFalse(TodoTask.isValidPlannedRange(start, end))
    }

    func test_非法_开始晚于结束() {
        let start = makeDate(2026, 8, 30, hour: 14)
        let end = makeDate(2026, 8, 30, hour: 10)
        XCTAssertFalse(TodoTask.isValidPlannedRange(start, end))
    }

    func test_非法_开始等于结束() {
        let start = makeDate(2026, 8, 30, hour: 10)
        XCTAssertFalse(TodoTask.isValidPlannedRange(start, start))
    }

    // MARK: - Repository 读写

    func test_创建带时间段_成对落库() throws {
        let (repo, _) = try makeRepo()
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 12)
        let task = try repo.createTask(title: "跑步", plannedStart: start, plannedEnd: end)

        XCTAssertTrue(task.hasPlannedTimeRange)
        XCTAssertEqual(task.plannedStart, start)
        XCTAssertEqual(task.plannedEnd, end)
    }

    func test_创建不带时间段_两字段为空() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "普通待办")

        XCTAssertFalse(task.hasPlannedTimeRange)
        XCTAssertNil(task.plannedStart)
        XCTAssertNil(task.plannedEnd)
    }

    func test_更新set覆盖时间段() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "T")
        let start = makeDate(2026, 8, 31, hour: 9)
        let end = makeDate(2026, 8, 31, hour: 11)

        try repo.updateTask(task, plannedTime: .set(start: start, end: end))

        XCTAssertEqual(task.plannedStart, start)
        XCTAssertEqual(task.plannedEnd, end)
    }

    func test_更新clear清空时间段() throws {
        let (repo, _) = try makeRepo()
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 12)
        let task = try repo.createTask(title: "T", plannedStart: start, plannedEnd: end)

        try repo.updateTask(task, plannedTime: .clear)

        XCTAssertFalse(task.hasPlannedTimeRange)
        XCTAssertNil(task.plannedStart)
        XCTAssertNil(task.plannedEnd)
    }

    func test_更新不传plannedTime_保留原值() throws {
        let (repo, _) = try makeRepo()
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 12)
        let task = try repo.createTask(title: "T", plannedStart: start, plannedEnd: end)

        // 只改标题，不碰时间段
        try repo.updateTask(task, title: "改名")

        XCTAssertEqual(task.title, "改名")
        XCTAssertEqual(task.plannedStart, start)
        XCTAssertEqual(task.plannedEnd, end)
    }

    // MARK: - updateTask 清单 nil 语义（TaskListUpdate）

    func test_更新清单clear_移回收件箱() throws {
        let (repo, _) = try makeRepo()
        let list = try repo.createList(name: "测试清单")
        let task = try repo.createTask(title: "T", list: list)
        XCTAssertEqual(task.list?.name, "测试清单")

        // 「收件箱」是显式保存意图：不能被 nil=不修改 语义吞掉（历史 bug：
        // 任务从清单改选收件箱后静默失效，永远留在原清单）
        try repo.updateTask(task, list: .clear)

        XCTAssertNil(task.list)
    }

    func test_更新清单不传list_保留原清单() throws {
        let (repo, _) = try makeRepo()
        let list = try repo.createList(name: "测试清单")
        let task = try repo.createTask(title: "T", list: list)

        // 只改标题，不碰清单
        try repo.updateTask(task, title: "改名")

        XCTAssertEqual(task.title, "改名")
        XCTAssertEqual(task.list?.name, "测试清单")
    }

    // MARK: - 计划 vs 实际

    func test_计划时长计算() throws {
        let (repo, _) = try makeRepo()
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 11, minute: 30)
        let task = try repo.createTask(title: "T", plannedStart: start, plannedEnd: end)

        XCTAssertEqual(task.plannedDurationMinutes, 90)
    }

    func test_记录与清除实际用时() throws {
        let (repo, _) = try makeRepo()
        let start = makeDate(2026, 8, 30, hour: 10)
        let end = makeDate(2026, 8, 30, hour: 12)
        let task = try repo.createTask(title: "T", plannedStart: start, plannedEnd: end)

        try repo.setActualDuration(task, minutes: 45)
        XCTAssertEqual(task.actualDurationMinutes?.intValue, 45)

        try repo.setActualDuration(task, minutes: nil)
        XCTAssertNil(task.actualDurationMinutes)
    }

    func test_实际用时负值被钳为0() throws {
        let (repo, _) = try makeRepo()
        let task = try repo.createTask(title: "T")

        try repo.setActualDuration(task, minutes: -10)
        XCTAssertEqual(task.actualDurationMinutes?.intValue, 0)
    }
}

// MARK: - AI 建任务的清单归属（TodoListNameResolver + matchOrCreateList）

final class TodoListAssignmentTests: XCTestCase {

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TodoListAssignmentTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TodoRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    // MARK: - TodoListNameResolver 纯逻辑

    func test_清理_剥引号与空白并限长() {
        XCTAssertEqual(TodoListNameResolver.clean(" 「日本旅行」 "), "日本旅行")
        let long = String(repeating: "旅", count: 20)
        XCTAssertEqual(TodoListNameResolver.clean(long).count, TodoListNameResolver.maxNameLength)
    }

    func test_判定_精确命中已有清单() {
        let r = TodoListNameResolver.resolve(suggested: "日本旅行", existingListNames: ["购物", "日本旅行"])
        XCTAssertEqual(r?.matchedExistingName, "日本旅行")
    }

    func test_判定_唯一模糊命中() {
        let r = TodoListNameResolver.resolve(suggested: "日本旅行", existingListNames: ["购物", "日本旅行准备"])
        XCTAssertEqual(r?.matchedExistingName, "日本旅行准备")
    }

    func test_判定_多命中视为主题不明确_新建() {
        let r = TodoListNameResolver.resolve(suggested: "旅行", existingListNames: ["日本旅行", "三亚旅行"])
        XCTAssertNil(r?.matchedExistingName)
        XCTAssertEqual(r?.name, "旅行")
    }

    func test_判定_无相近清单_新建() {
        let r = TodoListNameResolver.resolve(suggested: "日本旅行", existingListNames: ["购物"])
        XCTAssertNil(r?.matchedExistingName)
        XCTAssertEqual(r?.name, "日本旅行")
    }

    func test_判定_清完为空_返回nil落默认位置() {
        XCTAssertNil(TodoListNameResolver.resolve(suggested: "「」", existingListNames: ["购物"]))
    }

    // MARK: - matchOrCreateList 落库行为

    func test_归属_无命中自动创建清单() throws {
        let (repo, _) = try makeRepo()
        let outcome = try repo.matchOrCreateList(named: "日本旅行")
        XCTAssertEqual(outcome?.created, true)
        XCTAssertEqual(outcome?.list.name, "日本旅行")
        XCTAssertEqual(repo.unfiledLists.map(\.name), ["日本旅行"])
    }

    func test_归属_二次同名复用已有清单不重复建() throws {
        let (repo, _) = try makeRepo()
        let first = try repo.matchOrCreateList(named: "日本旅行")
        XCTAssertEqual(first?.created, true)
        let second = try repo.matchOrCreateList(named: "日本旅行")
        XCTAssertEqual(second?.created, false)
        XCTAssertEqual(second?.list.id, first?.list.id)
        XCTAssertEqual(repo.unfiledLists.count, 1)
    }

    func test_归属_垃圾输入返回nil不建清单() throws {
        let (repo, _) = try makeRepo()
        let outcome = try repo.matchOrCreateList(named: "  「」 ")
        XCTAssertNil(outcome)
        XCTAssertTrue(repo.unfiledLists.isEmpty)
    }
}
