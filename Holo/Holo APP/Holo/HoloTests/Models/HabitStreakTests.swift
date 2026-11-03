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

    // MARK: - 每日结算时间（结算前的凌晨打卡归前一天，见 HabitDayAttribution）

    /// 结算 4:00：次日 0:30 的实时记录归属前一天；补签记录按目标日不平移；范围查询按归属时刻判定
    func test_结算时间_仓储按归属日取记录() throws {
        let (repo, ctx) = try makeRepo()
        let calendar = Calendar.current
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.dayEndTime = (hour: 4, minute: 0)
        let day = dayStart(3)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let next0030 = calendar.date(byAdding: .minute, value: 30, to: nextDay)!
        try makeRecord(in: ctx, habitId: habit.id, date: next0030)
        let retro = try makeRecord(in: ctx, habitId: habit.id, date: dayStart(4))
        retro.isRetroactive = true
        try ctx.save()

        XCTAssertEqual(repo.records(for: habit, on: day).map(\.date), [next0030], "次日 0:30 的打卡归前一天")
        XCTAssertTrue(repo.records(for: habit, on: nextDay).isEmpty)
        XCTAssertEqual(repo.records(for: habit, on: dayStart(4)).count, 1, "补签记录仍归目标日")

        let dayEnd = calendar.date(byAdding: .second, value: 24 * 3600 - 1, to: day)!
        XCTAssertEqual(repo.getRecords(for: habit, in: day...dayEnd).count, 1)
        XCTAssertEqual(repo.calculatePeriodCompletionCount(for: habit, dateRange: day...dayEnd), 1)
        let dayAfterNext = calendar.date(byAdding: .day, value: 1, to: nextDay)!
        XCTAssertEqual(repo.getRecords(for: habit, in: nextDay...dayAfterNext).count, 0)
    }

    /// 核心场景：T-2 日 23:30 与 T 日 0:30 两次打卡——结算 4:00 下 T-2、T-1 连上 = 2；
    /// 默认结算下 0:30 算 T 日、T-1 空档，只剩今天 1 天
    func test_结算时间_凌晨打卡连续不断() throws {
        let (repo, ctx) = try makeRepo()
        let calendar = Calendar.current
        let night = makeHabit(in: ctx, createdAt: dayStart(30))
        night.dayEndTime = (hour: 4, minute: 0)
        let plain = makeHabit(in: ctx, createdAt: dayStart(30))
        try ctx.save()

        for habit in [night, plain] {
            let today = habit.currentDay()
            let twoDaysAgo2330 = calendar.date(byAdding: .minute, value: -(24 * 60) - 30, to: today)!
            let today0030 = calendar.date(byAdding: .minute, value: 30, to: today)!
            try makeRecord(in: ctx, habitId: habit.id, date: twoDaysAgo2330)
            try makeRecord(in: ctx, habitId: habit.id, date: today0030)
        }

        XCTAssertEqual(repo.calculateStreak(for: night), 2)
        XCTAssertEqual(repo.calculateStreak(for: plain), 1)
    }

    /// 此刻打卡恒归属习惯口径的「今天」：今日完成、今日进度与连续同时成立
    func test_结算时间_此刻打卡算今天() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.dayEndTime = (hour: 4, minute: 0)
        try ctx.save()
        repo.setup()

        XCTAssertTrue(try repo.toggleCheckIn(for: habit))
        XCTAssertTrue(repo.isTodayCompleted(for: habit))
        XCTAssertEqual(repo.getTodayCheckInProgress().completed, 1)
        XCTAssertEqual(repo.calculateStreak(for: habit), 1)
    }
}
