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
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "HabitRepoCalendarTest", managedObjectModel: model)
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

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    private func makeHabit(in ctx: NSManagedObjectContext,
                           name: String,
                           aggregationType: HabitAggregationType = .sum,
                           unit: String? = nil) -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: ctx) as! Habit
        habit.id = UUID()
        habit.name = name
        habit.icon = aggregationType == .latest ? "scalemass.fill" : "drop.fill"
        habit.color = "#3B82F6"
        habit.type = HabitType.numeric.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.unit = unit
        habit.aggregationType = aggregationType.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
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

    /// 构造数值记录（数值型习惯），可指定时刻，用于「今日最近一笔」撤销测试
    @discardableResult
    private func makeNumericRecord(in ctx: NSManagedObjectContext,
                                   habitId: UUID,
                                   value: Double,
                                   date: Date) throws -> HabitRecord {
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: ctx) as! HabitRecord
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
        let habit = makeHabit(in: ctx, name: "喝水", unit: "杯")
        try ctx.save()

        let today = Calendar.current.startOfDay(for: Date())
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: today.addingTimeInterval(8 * 3600))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: today.addingTimeInterval(9 * 3600))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 1, date: today.addingTimeInterval(10 * 3600))

        XCTAssertEqual(repo.getTodayValue(for: habit), 3, "前置：今日合计应为 3")

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertTrue(removed)
        XCTAssertEqual(repo.getTodayValue(for: habit), 2, "撤销后应删掉最新一条，合计回到 2")
        XCTAssertEqual(repo.getTodayRecords(for: habit).count, 2)
    }

    func test_撤销今日最近一笔_测量类回退到上一条() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "体重", aggregationType: .latest, unit: "kg")
        try ctx.save()

        let today = Calendar.current.startOfDay(for: Date())
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 70, date: today.addingTimeInterval(8 * 3600))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 71, date: today.addingTimeInterval(9 * 3600))

        XCTAssertEqual(repo.getTodayValue(for: habit), 71, "前置：测量类今日取最新 71")

        try repo.removeLatestTodayRecord(for: habit)
        XCTAssertEqual(repo.getTodayValue(for: habit), 70, "撤销最新后应回退到上一条 70")
    }

    func test_撤销今日无记录返回false不抛错() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "喝水", unit: "杯")
        try ctx.save()

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertFalse(removed, "今日无记录应返回 false 而非抛错")
    }

    func test_撤销只影响今日不影响昨日记录() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "喝水", unit: "杯")
        try ctx.save()

        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 5, date: yesterday)

        let removed = try repo.removeLatestTodayRecord(for: habit)
        XCTAssertFalse(removed, "今日无记录（只有昨日）应返回 false")
        XCTAssertEqual(repo.getAllRecords(for: habit).count, 1, "昨日记录不应被误删")
    }

    // MARK: - 数值统计有效值口径

    func test_近90天测量统计忽略较新的空记录() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "体重", aggregationType: .latest, unit: "kg")
        try ctx.save()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let oldDay = calendar.date(byAdding: .day, value: -80, to: today) ?? today
        let recentDay = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 72.4,
                              date: oldDay.addingTimeInterval(8 * 3600))
        try makeRecord(in: ctx, habitId: habit.id,
                       date: oldDay.addingTimeInterval(9 * 3600), completed: false)
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 70.1,
                              date: recentDay.addingTimeInterval(8 * 3600))

        let stats = repo.calculatePeriodStats(for: habit, range: .quarter)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.min, 70.1, accuracy: 0.000_001)
        XCTAssertEqual(stats.max, 72.4, accuracy: 0.000_001)
        XCTAssertEqual(stats.change ?? 0, -2.3, accuracy: 0.000_001)
        XCTAssertEqual(repo.getDailyAggregatedData(for: habit, range: .quarter).map(\.value),
                       [72.4, 70.1])
    }

    func test_全部范围无有效值时统计为空而不是有效零值() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "体重", aggregationType: .latest, unit: "kg")
        try ctx.save()
        try makeRecord(in: ctx, habitId: habit.id, date: Date(), completed: false)

        let stats = repo.calculatePeriodStats(for: habit, range: .all)
        XCTAssertEqual(stats.count, 0, "空值记录不能伪装成一条数值 0")
        XCTAssertNil(stats.change)
        XCTAssertTrue(repo.getDailyAggregatedData(for: habit, range: .all).isEmpty)
    }

    func test_今日测量值跳过最新空记录() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "体重", aggregationType: .latest, unit: "kg")
        try ctx.save()

        let now = Date()
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 70.5,
                              date: now.addingTimeInterval(-60))
        try makeRecord(in: ctx, habitId: habit.id, date: now, completed: false)

        XCTAssertEqual(repo.getTodayValue(for: habit), 70.5,
                       "最新空记录不能遮住今日最新有效测量值")
    }

    func test_自定义周期只统计起止日期内的有效测量值() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, name: "体重", aggregationType: .latest, unit: "kg")
        try ctx.save()

        try makeNumericRecord(in: ctx, habitId: habit.id, value: 73.0,
                              date: makeDate(year: 2026, month: 7, day: 9, hour: 12))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 72.0,
                              date: makeDate(year: 2026, month: 7, day: 10, hour: 8))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 71.2,
                              date: makeDate(year: 2026, month: 7, day: 12, hour: 23))
        try makeNumericRecord(in: ctx, habitId: habit.id, value: 70.8,
                              date: makeDate(year: 2026, month: 7, day: 13, hour: 8))

        let start = makeDate(year: 2026, month: 7, day: 10)
        let end = makeDate(year: 2026, month: 7, day: 12, hour: 23)
            .addingTimeInterval(59 * 60 + 59)
        let dateRange = start...end

        let stats = repo.calculatePeriodStats(for: habit, dateRange: dateRange)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.min, 71.2, accuracy: 0.000_001)
        XCTAssertEqual(stats.max, 72.0, accuracy: 0.000_001)
        XCTAssertEqual(stats.change ?? 0, -0.8, accuracy: 0.000_001)
        XCTAssertEqual(repo.getDailyAggregatedData(for: habit, dateRange: dateRange).map(\.value),
                       [72.0, 71.2])
    }
}
