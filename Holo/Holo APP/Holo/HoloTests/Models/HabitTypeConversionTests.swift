//
//  HabitTypeConversionTests.swift
//  HoloTests
//
//  单测编辑习惯切换类型（打卡型 ⇄ 数值型）的记录架桥转换：
//  数值→打卡：有数值的记录补已完成、数值保留；打卡→数值：已完成补 1、空记录清理；
//  转换幂等、来回切数据无损；类型未变不触发转换。
//

import XCTest
import CoreData
@testable import Holo

final class HabitTypeConversionTests: XCTestCase {

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "HabitTypeConversionTest", managedObjectModel: model)
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

    private func makeHabit(in ctx: NSManagedObjectContext, type: HabitType) -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: ctx) as! Habit
        habit.id = UUID()
        habit.name = "测试习惯"
        habit.icon = "drop.fill"
        habit.color = "#3B82F6"
        habit.type = type.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = makeDate(year: 2026, month: 1, day: 1)
        habit.updatedAt = habit.createdAt
        try? ctx.save()
        return habit
    }

    @discardableResult
    private func makeRecord(in ctx: NSManagedObjectContext,
                            habitId: UUID,
                            date: Date,
                            completed: Bool = true,
                            value: Double? = nil) throws -> HabitRecord {
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: ctx) as! HabitRecord
        r.id = UUID()
        r.habitId = habitId
        r.date = date
        r.isCompleted = completed
        r.value = value.map { NSNumber(value: $0) }
        r.createdAt = date
        try ctx.save()
        return r
    }

    // MARK: - 数值 → 打卡

    func test_数值转打卡_历史数值记录补已完成且数值保留() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), value: 35)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), value: 40)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .checkIn))

        XCTAssertEqual(habit.habitType, .checkIn)
        let records = repo.getAllRecords(for: habit)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.isCompleted })
        XCTAssertEqual(records.first { $0.valueDouble == 35 }?.valueDouble, 35)
        XCTAssertEqual(records.first { $0.valueDouble == 40 }?.valueDouble, 40)
    }

    func test_数值转打卡_空记录被清理且连续天数接上历史() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), value: 35)
        // 同步残留的空记录（无数值未完成）
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), completed: false, value: nil)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .checkIn))

        XCTAssertEqual(repo.getAllRecords(for: habit).count, 1, "空记录应被清理")
        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 1, "转换后的历史应计入打卡累计")
    }

    // MARK: - 打卡 → 数值

    func test_打卡转数值_已完成记录补1且取消记录被清理() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), completed: true)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), completed: true)
        // 勾了又取消的空记录
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 3), completed: false, value: nil)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .numeric))

        XCTAssertEqual(habit.habitType, .numeric)
        let records = repo.getAllRecords(for: habit)
        XCTAssertEqual(records.count, 2, "取消的空记录应被清理")
        XCTAssertEqual(repo.calculateLifetimeTotal(for: habit), 2, "历史打卡每次按 1 计入")
        XCTAssertTrue(records.allSatisfy { $0.valueDouble == 1 })
    }

    // MARK: - 来回切换与幂等

    func test_来回切换_数值无损() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .numeric)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), value: 35)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), value: 40)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .checkIn))
        try repo.updateHabit(habit, updates: HabitUpdates(type: .numeric))

        XCTAssertEqual(habit.habitType, .numeric)
        let records = repo.getAllRecords(for: habit)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.compactMap { $0.valueDouble }.sorted(), [35, 40], "来回切换后数值应原样保留")
        XCTAssertTrue(records.allSatisfy { $0.isCompleted }, "中途补的完成态保留，切回打卡不丢历史")
    }

    func test_重复提交相同类型_不重复转换() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), completed: true)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .numeric, name: "改名"))
        try repo.updateHabit(habit, updates: HabitUpdates(type: .numeric, name: "改名"))

        XCTAssertEqual(repo.getAllRecords(for: habit).count, 1)
        XCTAssertEqual(repo.getAllRecords(for: habit).first?.valueDouble, 1)
        XCTAssertEqual(habit.name, "改名")
    }

    func test_类型未变_不触发记录转换() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, type: .checkIn)
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 1), completed: true)
        // 取消的空记录在类型未变时必须原样保留（打卡型语义：保留取消痕迹）
        try makeRecord(in: ctx, habitId: habit.id, date: makeDate(year: 2026, month: 8, day: 2), completed: false, value: nil)

        try repo.updateHabit(habit, updates: HabitUpdates(type: .checkIn, name: "改名"))

        XCTAssertEqual(repo.getAllRecords(for: habit).count, 2, "类型未变不应清理任何记录")
        XCTAssertTrue(repo.getAllRecords(for: habit).contains { !$0.isCompleted }, "取消记录原样保留")
    }
}
