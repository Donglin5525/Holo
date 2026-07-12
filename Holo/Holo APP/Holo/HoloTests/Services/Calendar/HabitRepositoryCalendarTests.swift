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

    /// 构造数值记录（数值型习惯），可指定时刻，用于「今日最近一笔」撤销测试
    @discardableResult
    private func makeNumericRecord(in ctx: NSManagedObjectContext,
                                   habitId: UUID,
                                   value: Double,
                                   date: Date) throws -> HabitRecord {
        let r = HabitRecord(context: ctx)
        r.id = UUID()
        r.habitId = habitId
        r.date = date
        r.isCompleted = false
        r.value = NSNumber(value: value)
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

    // MARK: - removeLatestTodayRecord（撤销今日最近一笔）

    func test_撤销今日最近一笔_计数类删最新一条() throws {
        let (repo, ctx) = try makeRepo()
        let habit = Habit.create(in: ctx, name: "喝水", icon: "drop.fill",
                                 color: "#3B82F6", type: .numeric, unit: "杯")
        try ctx.save()

        let now = Date()
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: now.addingTimeInterval(-3600))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: now.addingTimeInterval(-1800))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: now)

        XCTAssertEqual(repo.getTodayValue(for: habit), 3, "前置：今日合计应为 3")

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertTrue(removed)
        XCTAssertEqual(repo.getTodayValue(for: habit), 2, "撤销后应删掉最新一条，合计回到 2")
        XCTAssertEqual(repo.getTodayRecords(for: habit).count, 2)
    }

    func test_撤销今日最近一笔_测量类回退到上一条() throws {
        let (repo, ctx) = try makeRepo()
        let habit = Habit.create(in: ctx, name: "体重", icon: "scalemass.fill",
                                 color: "#3B82F6", type: .numeric,
                                 aggregationType: .latest, unit: "kg")
        try ctx.save()

        let now = Date()
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 70, date: now.addingTimeInterval(-3600))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 71, date: now)

        XCTAssertEqual(repo.getTodayValue(for: habit), 71, "前置：测量类今日取最新 71")

        try repo.removeLatestTodayRecord(for: habit)
        XCTAssertEqual(repo.getTodayValue(for: habit), 70, "撤销最新后应回退到上一条 70")
    }

    func test_撤销今日无记录返回false不抛错() throws {
        let (repo, ctx) = try makeRepo()
        let habit = Habit.create(in: ctx, name: "喝水", icon: "drop.fill",
                                 color: "#3B82F6", type: .numeric, unit: "杯")
        try ctx.save()

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertFalse(removed, "今日无记录应返回 false 而非抛错")
    }

    func test_撤销只影响今日不影响昨日记录() throws {
        let (repo, ctx) = try makeRepo()
        let habit = Habit.create(in: ctx, name: "喝水", icon: "drop.fill",
                                 color: "#3B82F6", type: .numeric, unit: "杯")
        try ctx.save()

        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 5, date: yesterday)

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertFalse(removed, "今日无记录（只有昨日）应返回 false")
        XCTAssertEqual(repo.getAllRecords(for: habit).count, 1, "昨日记录不应被误删")
    }
}
