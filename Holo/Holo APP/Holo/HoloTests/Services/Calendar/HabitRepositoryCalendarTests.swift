//
//  HabitRepositoryCalendarTests.swift
//  HoloTests
//
//  日历聚合用 HabitRepository.getRecords(from:to:) 单测（半开区间、跨习惯、边界）
//

import XCTest
import CoreData
@testable import Holo

final class HabitRepositoryCalendarTests: XCTestCase {

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "HabitRepoCalendarTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (HabitRepository(context: ctx), ctx)
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
    private func makeRecord(in ctx: NSManagedObjectContext,
                            habitId: UUID,
                            date: Date,
                            completed: Bool = true) throws -> HabitRecord {
        let r = HabitRecord(context: ctx)
        r.id = UUID()
        r.habitId = habitId
        r.date = date
        r.isCompleted = completed
        r.createdAt = date
        try ctx.save()
        return r
    }

    func test_区间内记录返回并按时间升序() throws {
        let (repo, ctx) = try makeRepo()
        let hid = UUID()
        let d2 = try makeRecord(in: ctx, habitId: hid, date: makeDate(year: 2026, month: 7, day: 2, hour: 10))
        let d1 = try makeRecord(in: ctx, habitId: hid, date: makeDate(year: 2026, month: 7, day: 1, hour: 9))

        let records = repo.getRecords(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 3)
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.id, d1.id, "应按 date 升序")
        XCTAssertEqual(records.last?.id, d2.id)
    }

    func test_半开区间_次日零点不计入() throws {
        let (repo, ctx) = try makeRepo()
        let hid = UUID()
        try makeRecord(in: ctx, habitId: hid, date: makeDate(year: 2026, month: 7, day: 1, hour: 23))
        // 次日 00:00 不应计入 [7/1, 7/2)
        try makeRecord(in: ctx, habitId: hid, date: makeDate(year: 2026, month: 7, day: 2, hour: 0))

        let records = repo.getRecords(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(records.count, 1, "半开区间：7/2 00:00 不应计入 [7/1, 7/2)")
    }

    func test_跨习惯_不带habitId过滤() throws {
        let (repo, ctx) = try makeRepo()
        try makeRecord(in: ctx, habitId: UUID(), date: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeRecord(in: ctx, habitId: UUID(), date: makeDate(year: 2026, month: 7, day: 1, hour: 10))

        let records = repo.getRecords(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(records.count, 2, "应返回所有习惯的记录，不带 habitId 过滤")
    }

    func test_空区间返回空() throws {
        let (repo, _) = try makeRepo()
        let records = repo.getRecords(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(records.isEmpty)
    }
}
