//
//  ThoughtRepositoryCalendarTests.swift
//  HoloTests
//
//  日历聚合用 ThoughtRepository.fetchThoughts(from:to:) 单测
//  （半开区间、isSoftDeleted/isArchived 过滤、边界）
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtRepositoryCalendarTests: XCTestCase {

    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "ThoughtRepoCalendarTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (ThoughtRepository(context: ctx), ctx)
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
    private func makeThought(in ctx: NSManagedObjectContext,
                             content: String,
                             createdAt: Date,
                             softDeleted: Bool = false,
                             archived: Bool = false) throws -> Thought {
        let t = Thought(context: ctx)
        t.id = UUID()
        t.content = content
        t.createdAt = createdAt
        t.updatedAt = createdAt
        t.orderIndex = 0
        t.organizedStatus = "organized"
        t.isSoftDeleted = softDeleted
        t.isArchived = archived
        try ctx.save()
        return t
    }

    func test_区间内想法返回() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "A", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeThought(in: ctx, content: "B", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 20))

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 2)
    }

    func test_半开区间_次日零点不计入() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "A", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 23))
        try makeThought(in: ctx, content: "B", createdAt: makeDate(year: 2026, month: 7, day: 2, hour: 0))

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 1, "半开区间：7/2 00:00 不应计入")
    }

    func test_软删想法被过滤() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "正常", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeThought(in: ctx, content: "已删", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 10), softDeleted: true)

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 1, "isSoftDeleted==YES 应被过滤")
        XCTAssertEqual(thoughts.first?.content, "正常")
    }

    func test_空区间返回空() throws {
        let (repo, _) = try makeRepo()
        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(thoughts.isEmpty)
    }
}
