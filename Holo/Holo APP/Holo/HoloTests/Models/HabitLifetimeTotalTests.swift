//
//  HabitLifetimeTotalTests.swift
//  HoloTests
//
//  单测 HabitRepository.calculateLifetimeTotal 全历史累计口径：
//  打卡型好习惯=已完成次数（取消态不算、补签计入）；计数类=数值总和；
//  iCloud 同 id 副本去重不双计；坏习惯/测量类返回 nil。
//

import XCTest
import CoreData
@testable import Holo

final class HabitLifetimeTotalTests: XCTestCase {

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "HabitLifetimeTotalTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = HabitRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 9) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    private func makeHabit(in ctx: NSManagedObjectContext,
                           type: HabitType,
                           aggregationType: HabitAggregationType = .sum,
                           isBadHabit: Bool = false) -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: ctx) as! Habit
        habit.id = UUID()
        habit.name = "测试习惯"
        habit.icon = "drop.fill"
        habit.color = "#3B82F6"
        habit.type = type.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = aggregationType.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = makeDate(year: 2026, month: 1, day: 1)
        habit.updatedAt = habit.createdAt
        return habit
    }

    @discardableResult
    private func makeRecord(in ctx: NSManagedObjectContext,
                            habitId: UUID,
                            date: Date,
                            completed: Bool = true,
                            value: Double? = nil,
                            isRetroactive: Bool = false,
                            id: UUID = UUID()) throws -> HabitRecord {
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: ctx) as! HabitRecord
        r.id = id
        r.habitId = habitId
        r.date = date
        r.isCompleted = completed
        r.value = value.map { NSNumber(value: $0) }
        r.isRetroactive = isRetroactive
        r.createdAt = isRetroactive ? Date() : date
        try ctx.save()
        return r
    }

    // MARK: - 打卡型

    func test_打卡型_累计只数已完成_取消态不算() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), completed: true)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), completed: true)
        // 取消打卡：记录保留但 isCompleted = false
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 3), completed: false)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 2)
    }

    func test_打卡型_补签计入累计() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1))
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2))
        // 补签：date 归目标日，isRetroactive 标记
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 3), isRetroactive: true)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 3)
    }

    func test_打卡型_无记录累计为0() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 0)
    }

    // MARK: - 计数类

    func test_计数类_累计为全部数值总和() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric, aggregationType: .sum)
        // 第一天两笔 2+3，第二天一笔 4
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1, hour: 8), value: 2)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1, hour: 20), value: 3)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), value: 4)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 9)
    }

    func test_计数类_不串到其他习惯() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric, aggregationType: .sum)
        let other = makeHabit(in: ctx, type: .numeric, aggregationType: .sum)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), value: 5)
        try makeRecord(in: ctx, habitId: other.id, date: makeDate(year: 2026, month: 8, day: 1), value: 100)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 5)
    }

    // MARK: - iCloud 同 id 副本

    func test_同id重复行_累计不双计() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        let duplicatedId = UUID()
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), id: duplicatedId)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), id: duplicatedId)

        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 1, "iCloud 同 id 副本应去重后计数")
    }

    // MARK: - 不展示类型

    func test_坏习惯返回nil() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn, isBadHabit: true)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1))

        XCTAssertNil(repo.calculateLifetimeTotal(for: habit))
    }

    func test_测量类返回nil() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric, aggregationType: .latest)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), value: 60)

        XCTAssertNil(repo.calculateLifetimeTotal(for: habit))
    }
}
