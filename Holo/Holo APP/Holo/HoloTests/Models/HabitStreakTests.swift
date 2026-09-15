//
//  HabitStreakTests.swift
//  HoloTests
//
//  单测连续天数口径：回溯物理下限 = 习惯创建日。
//  修复点：坏习惯 0 记录时不再凭空累计到回溯上限（曾显示 3650 天/520 周）。
//

import XCTest
import CoreData
@testable import Holo

final class HabitStreakTests: XCTestCase {

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "HabitStreakTest", managedObjectModel: model)
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

    private func dayStart(_ numberOfDaysAgo: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -numberOfDaysAgo, to: Date()) ?? Date()
        return calendar.startOfDay(for: day)
    }

    private func makeHabit(in ctx: NSManagedObjectContext,
                           frequency: HabitFrequency = .daily,
                           isBadHabit: Bool = false,
                           createdAt: Date = Date()) -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: ctx) as! Habit
        habit.id = UUID()
        habit.name = "测试习惯"
        habit.icon = "drop.fill"
        habit.color = "#3B82F6"
        habit.type = HabitType.checkIn.rawValue
        habit.frequency = frequency.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = createdAt
        habit.updatedAt = createdAt
        return habit
    }

    @discardableResult
    private func makeRecord(in ctx: NSManagedObjectContext,
                            habitId: UUID,
                            date: Date,
                            completed: Bool = true) throws -> HabitRecord {
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: ctx) as! HabitRecord
        r.id = UUID()
        r.habitId = habitId
        r.date = date
        r.isCompleted = completed
        r.createdAt = date
        try ctx.save()
        return r
    }

    // MARK: - 坏习惯（daily）

    func test_新建坏习惯0记录_连续克制只算创建当天() throws {
        let (repo, ctx) = try makeRepo()
        // 今天创建，无任何记录：只有今天 1 天克制，不得顶满 3650
        let habit = makeHabit(in: ctx, isBadHabit: true, createdAt: Date())
        try ctx.save()

        XCTAssertEqual(repo.calculateStreak(for: habit), 1)
    }

    func test_坏习惯_最近一次犯错后中断() throws {
        let (repo, ctx) = try makeRepo()
        // 30 天前创建，3 天前犯过一次：之后（前天/昨天/今天）连续克制 3 天
        let habit = makeHabit(in: ctx, isBadHabit: true, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(3))

        XCTAssertEqual(repo.calculateStreak(for: habit), 3)
    }

    func test_坏习惯_创建日为回溯下限() throws {
        let (repo, ctx) = try makeRepo()
        // 3 天前创建且从未犯错：克制 = 大前天(创建日)/前天/昨天/今天 共 4 天
        let habit = makeHabit(in: ctx, isBadHabit: true, createdAt: dayStart(3))

        XCTAssertEqual(repo.calculateStreak(for: habit), 4)
    }

    // MARK: - 好习惯（daily，不回归）

    func test_新建好习惯0记录_连续为0() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: Date())

        XCTAssertEqual(repo.calculateStreak(for: habit), 0)
    }

    func test_好习惯_连续打卡天数() throws {
        let (repo, ctx) = try makeRepo()
        // 30 天前创建，昨天/前天/大前天连续打卡，今天未打：连续 3 天
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(1))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(2))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(3))

        XCTAssertEqual(repo.calculateStreak(for: habit), 3)
    }

    // MARK: - 坏习惯（weekly/monthly）

    func test_周频率坏习惯0记录_不再凭空累计() throws {
        let (repo, ctx) = try makeRepo()
        // 今天创建的周频率坏习惯：创建前的周不存在「控制住」，不得累计到 520 周上限
        let habit = makeHabit(in: ctx, frequency: .weekly, isBadHabit: true, createdAt: Date())
        try ctx.save()

        let streak = repo.calculateStreakInfo(for: habit)
        XCTAssertEqual(streak.value, 0)
        XCTAssertEqual(streak.unit, .week)
    }

    func test_月频率坏习惯0记录_不再凭空累计() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, frequency: .monthly, isBadHabit: true, createdAt: Date())
        try ctx.save()

        let streak = repo.calculateStreakInfo(for: habit)
        XCTAssertEqual(streak.value, 0)
        XCTAssertEqual(streak.unit, .month)
    }
}
