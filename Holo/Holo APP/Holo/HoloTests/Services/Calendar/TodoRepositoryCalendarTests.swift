//
//  TodoRepositoryCalendarTests.swift
//  HoloTests
//
//  日历聚合用 TodoRepository.getTasks(completedFrom:completedTo:) 单测
//  （半开区间、deletedFlag/archived 过滤、边界）
//

import XCTest
import CoreData
@testable import Holo

final class TodoRepositoryCalendarTests: XCTestCase {

    private func makeRepo() throws -> (TodoRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "TodoRepoCalendarTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (TodoRepository(context: ctx), ctx)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    @discardableResult
    private func makeTask(in ctx: NSManagedObjectContext,
                          title: String,
                          completedAt: Date) throws -> TodoTask {
        let t = TodoTask(context: ctx)
        t.id = UUID()
        t.title = title
        t.completedAt = completedAt
        t.completed = true
        t.deletedFlag = false
        t.archived = false
        t.createdAt = completedAt
        try ctx.save()
        return t
    }

    func test_区间内已完成任务返回() throws {
        let (repo, ctx) = try makeRepo()
        try makeTask(in: ctx, title: "T1", completedAt: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeTask(in: ctx, title: "T2", completedAt: makeDate(year: 2026, month: 7, day: 1, hour: 18))

        let tasks = repo.getTasks(
            completedFrom: makeDate(year: 2026, month: 7, day: 1),
            completedTo: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(tasks.count, 2)
    }

    func test_半开区间_次日零点不计入() throws {
        let (repo, ctx) = try makeRepo()
        try makeTask(in: ctx, title: "T1", completedAt: makeDate(year: 2026, month: 7, day: 1, hour: 23))
        try makeTask(in: ctx, title: "T2", completedAt: makeDate(year: 2026, month: 7, day: 2, hour: 0))

        let tasks = repo.getTasks(
            completedFrom: makeDate(year: 2026, month: 7, day: 1),
            completedTo: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(tasks.count, 1, "半开区间：7/2 00:00 不应计入")
    }

    func test_已删除任务被过滤() throws {
        let (repo, ctx) = try makeRepo()
        let t = TodoTask(context: ctx)
        t.id = UUID()
        t.title = "已删"
        t.completedAt = makeDate(year: 2026, month: 7, day: 1, hour: 9)
        t.completed = true
        t.deletedFlag = true
        t.archived = false
        t.createdAt = t.completedAt ?? Date()
        try ctx.save()

        let tasks = repo.getTasks(
            completedFrom: makeDate(year: 2026, month: 7, day: 1),
            completedTo: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(tasks.isEmpty, "deletedFlag==YES 应被过滤")
    }

    func test_空区间返回空() throws {
        let (repo, _) = try makeRepo()
        let tasks = repo.getTasks(
            completedFrom: makeDate(year: 2026, month: 7, day: 1),
            completedTo: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(tasks.isEmpty)
    }
}
