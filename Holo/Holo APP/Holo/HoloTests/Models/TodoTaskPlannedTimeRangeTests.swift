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
}
