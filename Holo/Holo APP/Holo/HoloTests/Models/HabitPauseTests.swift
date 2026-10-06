//
//  HabitPauseTests.swift
//  HoloTests
//
//  单测习惯暂停冻结口径：连续天数不算断、不计数；完成率分母挖掉冻结日；
// 暂停/恢复状态机与到期自动恢复。
//

import XCTest
import CoreData
@testable import Holo

final class HabitPauseTests: XCTestCase {

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "HabitPauseTest", managedObjectModel: model)
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

    // MARK: - 窗口判断

    func test_窗口编解码往返() {
        let (repo, ctx) = try! makeRepo()
        _ = repo
        let habit = makeHabit(in: ctx)
        habit.pauseWindows = [
            HabitPauseWindow(startDate: dayStart(10), endDate: dayStart(5)),
            HabitPauseWindow(startDate: dayStart(2), endDate: nil)
        ]
        XCTAssertEqual(habit.pauseWindows.count, 2)
        XCTAssertEqual(habit.openPauseWindow?.startDate, dayStart(2))
    }

    func test_开放窗口_覆盖窗口起点到今天() {
        let (_, ctx) = try! makeRepo()
        let habit = makeHabit(in: ctx)
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: nil)]

        XCTAssertTrue(habit.isDayPaused(Date()))          // 今天
        XCTAssertTrue(habit.isDayPaused(dayStart(3)))     // 起点
        XCTAssertFalse(habit.isDayPaused(dayStart(4)))    // 起点前一天
    }

    func test_已关窗口_不含恢复日之后() {
        let (_, ctx) = try! makeRepo()
        let habit = makeHabit(in: ctx)
        // 窗口 [3天前, 1天前]：恢复日 = 昨天
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: dayStart(1))]

        XCTAssertTrue(habit.isDayPaused(dayStart(2)))
        XCTAssertTrue(habit.isDayPaused(dayStart(1)))
        XCTAssertFalse(habit.isDayPaused(Date()))
        XCTAssertFalse(habit.isDayPaused(dayStart(4)))
    }

    // MARK: - 好习惯连续天数冻结（东林拍板：47天暂停10天回来显示48）

    func test_暂停中_连续天数冻结不掉零() throws {
        let (repo, ctx) = try makeRepo()
        // 昨天/前天/大前天连续打卡 3 天，今天起暂停中（开放窗口）
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(1))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(2))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(3))
        try repo.pauseHabit(habit)

        // 冻结：今天跳过不算断，从昨天起算 3 天
        XCTAssertEqual(repo.calculateStreak(for: habit), 3)
    }

    func test_恢复后_连续天数从冻结处接续() throws {
        let (repo, ctx) = try makeRepo()
        // 暂停前打 2 天（12/11 天前）；窗口冻结 [10天前, 5天前]，恢复日 = 4 天前；
        // 恢复后打 4 天（4/3/2/1 天前），今天未打
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(12))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(11))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(4))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(3))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(2))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(1))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(10), endDate: dayStart(5))]
        try ctx.save()

        // 恢复后 4 天 + 冻结跳过 + 暂停前 2 天 = 6
        XCTAssertEqual(repo.calculateStreak(for: habit), 6)
    }

    func test_冻结不掩盖真实漏卡() throws {
        let (repo, ctx) = try makeRepo()
        // 暂停前打 2 天；恢复后一天都没打：冻结豁免只覆盖窗口内，
        // 窗口外的漏卡照常断（冻结 ≠ 无限豁免）
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(12))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(11))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(10), endDate: dayStart(5))]
        try ctx.save()

        XCTAssertEqual(repo.calculateStreak(for: habit), 0)
    }

    func test_暂停当天已打卡_照常计数() throws {
        let (repo, ctx) = try makeRepo()
        // 今天打卡后才暂停：记录优先于窗口，今天照算（数字不掉）
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try makeRecord(in: ctx, habitId: habit.id, date: dayStart(1))
        try makeRecord(in: ctx, habitId: habit.id, date: Date())
        try repo.pauseHabit(habit)

        XCTAssertEqual(repo.calculateStreak(for: habit), 2)
    }

    // MARK: - 坏习惯克制天数冻结

    func test_坏习惯_暂停日不算克制也不算破戒() throws {
        let (repo, ctx) = try makeRepo()
        // 20 天前创建从未犯错；窗口冻结 [5天前, 昨天]：克制 = 今天 + 6..20天前 = 16 天
        // （若不冻结会是 21 天；若算破戒会是 0 天）
        let habit = makeHabit(in: ctx, isBadHabit: true, createdAt: dayStart(20))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(5), endDate: dayStart(1))]
        try ctx.save()

        XCTAssertEqual(repo.calculateStreak(for: habit), 16)
    }

    // MARK: - 周频率整周冻结

    func test_周频率_整周暂停_连续周数冻结接续() throws {
        let (repo, ctx) = try makeRepo()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!

        let habit = makeHabit(in: ctx, frequency: .weekly, createdAt: dayStart(70))
        habit.targetCountValue = 1

        // 过去 8 周（w=0 当前周）每周中段打卡一次
        for weekOffset in 0..<8 {
            let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: thisWeek.start)!
            let midWeek = calendar.date(byAdding: .day, value: 3, to: weekStart)!
            try makeRecord(in: ctx, habitId: habit.id, date: midWeek)
        }

        // 冻结完整覆盖第 3、4 周前的两周（时间上更早的 w4.start 到更近的 w3 末日）
        let week3Start = calendar.date(byAdding: .weekOfYear, value: -3, to: thisWeek.start)!
        let week4Start = calendar.date(byAdding: .weekOfYear, value: -4, to: thisWeek.start)!
        let frozenEnd = calendar.date(byAdding: .day, value: 6, to: week3Start)!
        habit.pauseWindows = [HabitPauseWindow(startDate: week4Start, endDate: frozenEnd)]
        try ctx.save()

        // 当前周到 w=2 共 3 周 + 跳过 w=3/w=4 + w=5..w=7 共 3 周 = 6
        let info = repo.calculateStreakInfo(for: habit)
        XCTAssertEqual(info.value, 6)
        XCTAssertEqual(info.unit, .week)
    }

    // MARK: - 完成率分母

    func test_完成率分母_挖掉冻结日() throws {
        let (repo, ctx) = try makeRepo()
        // 区间 10 天（9 天前到今天），冻结 [4天前, 2天前] 共 3 天；
        // 有效 7 天全部有记录 → 100%（不挖则是 70%）
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        for offset in [9, 8, 7, 6, 5, 1] {
            try makeRecord(in: ctx, habitId: habit.id, date: dayStart(offset))
        }
        try makeRecord(in: ctx, habitId: habit.id, date: Date())
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(4), endDate: dayStart(2))]
        try ctx.save()

        let range = dayStart(9)...Date()
        XCTAssertEqual(repo.pausedDayCount(for: habit, in: range), 3)
        XCTAssertEqual(repo.calculateCheckInCompletionRate(for: habit, in: range), 100, accuracy: 0.01)
    }

    func test_窗口统计_只数区间内冻结日() {
        let (repo, ctx) = try! makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(60))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: dayStart(1))]

        // 窗口 3 天，但区间只覆盖 [5天前, 2天前]：只数到 2 天
        XCTAssertEqual(repo.pausedDayCount(for: habit, in: dayStart(5)...dayStart(2)), 2)
    }

    // MARK: - 补签漏卡排除冻结日

    func test_冻结日不算漏卡() throws {
        let (repo, ctx) = try makeRepo()
        // 7 天前创建无记录，窗口冻结 [3天前, 1天前]：
        // 补签候选 = 6/5/4 天前共 3 天（冻结日排除）
        let habit = makeHabit(in: ctx, createdAt: dayStart(7))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: dayStart(1))]
        try ctx.save()

        let days = repo.retroactiveEligibleDays(for: habit)
        XCTAssertEqual(days.count, 3)
        XCTAssertFalse(days.contains(where: { [1, 2, 3].contains(Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? -1) }))
    }

    // MARK: - 状态机

    func test_暂停_退出活跃列表进入暂停列表() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try ctx.save()
        repo.setup()

        XCTAssertTrue(repo.activeHabits.contains { $0.id == habit.id })
        try repo.pauseHabit(habit, until: Calendar.current.date(byAdding: .day, value: 3, to: Date()))

        XCTAssertTrue(habit.isPaused)
        XCTAssertFalse(repo.activeHabits.contains { $0.id == habit.id })
        XCTAssertTrue(repo.pausedHabits.contains { $0.id == habit.id })
        XCTAssertEqual(habit.pauseWindows.last?.endDate, nil)
    }

    func test_恢复_关窗到昨天回到活跃列表() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.isPaused = true
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: nil)]
        try ctx.save()
        repo.setup()

        try repo.resumeHabit(habit)

        XCTAssertFalse(habit.isPaused)
        XCTAssertNil(habit.pausedUntil)
        XCTAssertTrue(repo.activeHabits.contains { $0.id == habit.id })
        XCTAssertTrue(repo.pausedHabits.isEmpty)
        XCTAssertEqual(habit.pauseWindows.last?.endDate, dayStart(1))
    }

    func test_当天暂停当天恢复_无效窗口不落库() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try repo.pauseHabit(habit)
        try repo.resumeHabit(habit)

        XCTAssertTrue(habit.pauseWindows.isEmpty)
        XCTAssertFalse(habit.isDayPaused(Date()))
    }

    func test_打卡闸_暂停期拒绝打卡() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try ctx.save()
        try repo.pauseHabit(habit)

        let toggled = try repo.toggleCheckIn(for: habit)
        XCTAssertFalse(toggled)

        let records = repo.getRecords(for: habit, in: nil)
        XCTAssertTrue(records.isEmpty)
    }

    func test_到期自动恢复_恢复日一并冻结() throws {
        let (repo, ctx) = try makeRepo()
        // pausedUntil = 昨天（已到期）：加载时自动恢复，恢复日 = 今天。
        // 自动恢复是静默的：用户可能没打开过习惯页（出境深夜到点恢复实锤），
        // 恢复日也冻结——漏卡不断，从明天起重新站岗
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.isPaused = true
        habit.pausedUntil = dayStart(1)
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: nil)]
        try ctx.save()

        repo.loadActiveHabits()

        XCTAssertFalse(habit.isPaused)
        XCTAssertTrue(repo.activeHabits.contains { $0.id == habit.id })
        // 窗口 [3天前, 今天]：计划昨天恢复但今天才打开 App，
        // 昨天和今天都算没见过的日子，全冻结
        XCTAssertEqual(habit.pauseWindows.last?.endDate, dayStart(0))
        XCTAssertTrue(habit.isDayPaused(Date()))
        XCTAssertTrue(habit.isDayPaused(dayStart(1)))
        XCTAssertTrue(habit.isDayPaused(dayStart(2)))
    }

    func test_手动恢复_关窗到昨天_恢复日照常站岗() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.isPaused = true
        // 定时暂停未到期就手动恢复：走手动语义（恢复日站岗），不触发自动恢复的冻结
        habit.pausedUntil = Calendar.current.date(byAdding: .day, value: 3, to: Date())
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: nil)]
        try ctx.save()

        try repo.resumeHabit(habit)

        // 手动恢复是用户在场操作：恢复日当天照常要求打卡，只冻结到昨天
        XCTAssertEqual(habit.pauseWindows.last?.endDate, dayStart(1))
        XCTAssertFalse(habit.isDayPaused(Date()))
        XCTAssertTrue(habit.isDayPaused(dayStart(1)))
        XCTAssertNil(habit.pausedUntil)
    }

    func test_未到期_不自动恢复() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.isPaused = true
        habit.pausedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(1), endDate: nil)]
        try ctx.save()

        repo.loadActiveHabits()

        XCTAssertTrue(habit.isPaused)
        XCTAssertTrue(repo.pausedHabits.contains { $0.id == habit.id })
    }

    // MARK: - 窗口边界自愈（异时区写坏的对齐回整日）

    func test_窗口修复_异时刻终点进位到次日零点() throws {
        let (repo, ctx) = try makeRepo()
        let calendar = Calendar.current
        // 模拟东九区关窗写出的边界：昨天 23:00（北京时间）= 当地零点
        let skewedEnd = calendar.date(byAdding: .hour, value: 23, to: dayStart(1))!
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: skewedEnd)]
        try ctx.save()

        HabitPauseWindowRepair.repairIfNeeded(context: ctx)

        // 终点进位到今天零点：昨天整天回到冻结区
        XCTAssertEqual(habit.pauseWindows.first?.endDate, dayStart(0))
        XCTAssertEqual(habit.pauseWindows.first?.startDate, dayStart(3))
        XCTAssertTrue(habit.isDayPaused(dayStart(1)))
    }

    func test_窗口修复_已对齐边界幂等不动() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        habit.pauseWindows = [HabitPauseWindow(startDate: dayStart(3), endDate: dayStart(1))]
        try ctx.save()
        let before = habit.pauseWindows

        HabitPauseWindowRepair.repairIfNeeded(context: ctx)

        XCTAssertEqual(habit.pauseWindows, before)
    }

    func test_窗口修复_时区破洞冻结周恢复整周冻结() throws {
        let (repo, ctx) = try makeRepo()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!

        let habit = makeHabit(in: ctx, frequency: .weekly, createdAt: dayStart(70))
        habit.targetCountValue = 1
        // 前几周每周中段打卡一次
        for weekOffset in [2, 3, 4] {
            let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: thisWeek.start)!
            try makeRecord(in: ctx, habitId: habit.id, date: calendar.date(byAdding: .day, value: 3, to: weekStart)!)
        }
        // 上周整周暂停，但终点被异时区关窗写成周六 23:00——周日破洞，整周冻结判定失效
        let skewedEnd = calendar.date(byAdding: .hour, value: 23, to: calendar.date(byAdding: .day, value: 5, to: lastWeekStart)!)!
        habit.pauseWindows = [HabitPauseWindow(startDate: lastWeekStart, endDate: skewedEnd)]
        try ctx.save()

        // 破洞：上周按 0 次完成判定，连续断在暂停周
        XCTAssertEqual(repo.calculateStreakInfo(for: habit).value, 0)

        HabitPauseWindowRepair.repairIfNeeded(context: ctx)

        // 修复：上周整周冻结跳过，连续从冻结处接续（当前周未达标不计，回看 3 周）
        let info = repo.calculateStreakInfo(for: habit)
        XCTAssertEqual(info.value, 3)
        XCTAssertEqual(info.unit, .week)
    }

    // MARK: - 周点阵口径（取消打卡当天不算命中）

    func test_周点阵_取消打卡当天不算命中() throws {
        let (repo, ctx) = try makeRepo()
        let habit = makeHabit(in: ctx, createdAt: dayStart(30))
        try ctx.save()
        repo.setup()

        try repo.toggleCheckIn(for: habit)
        XCTAssertTrue(repo.getWeekCompletionPatterns()[habit.id]?.last == true)

        // 取消打卡：记录行保留（isCompleted 翻回 NO），点阵不得再把今天算命中
        try repo.toggleCheckIn(for: habit)
        let pattern = repo.getWeekCompletionPatterns()[habit.id]
        XCTAssertTrue(pattern == nil || pattern?.last == false)
    }
}
