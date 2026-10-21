//
//  HabitPresentationProjectorTests.swift
//  HoloTests
//
//  2026-10 习惯交互重构投影层验证：
//  记录/达标分离、真实 0、数值连续新口径（含冻结空日）、滚动七天、
//  打卡连续与 repository 原口径逐一对齐。
//

import XCTest
import CoreData
@testable import Holo

final class HabitPresentationProjectorTests: XCTestCase {

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?
    private var repo: HabitRepository?

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitProjectionTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        c.persistentStoreDescriptions = [description]
        var storeError: Error?
        c.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let context = c.viewContext
        let repository = HabitRepository(context: context)
        CoreDataTestSupport.retain(c, context, repository)
        container = c
        ctx = context
        repo = repository
        return (repository, context)
    }

    private func makeHabit(in context: NSManagedObjectContext,
                           type: HabitType = .checkIn,
                           aggregation: HabitAggregationType = .sum,
                           frequency: HabitFrequency = .daily,
                           isBadHabit: Bool = false,
                           targetCount: Int? = nil,
                           targetValue: Double? = nil,
                           unit: String? = nil,
                           createdAtDaysAgo: Int = 30) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = "测试习惯"
        habit.icon = "drop.fill"
        habit.color = "#3B76C9"
        habit.type = type.rawValue
        habit.frequency = frequency.rawValue
        habit.aggregationType = aggregation.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Calendar.current.date(byAdding: .day, value: -createdAtDaysAgo, to: Date())!
        habit.updatedAt = habit.createdAt
        habit.targetCount = targetCount.map { NSNumber(value: $0) }
        habit.targetValue = targetValue.map { NSNumber(value: $0) }
        habit.unit = unit
        return habit
    }

    @discardableResult
    private func makeRecord(in context: NSManagedObjectContext,
                            habit: Habit,
                            daysAgo: Int,
                            hour: Int = 10,
                            completed: Bool = true,
                            value: Double? = nil,
                            retroactive: Bool = false) throws -> HabitRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        var withHour = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        // 凌晨跑测试时「当天 10 点」在未来，会被投影层 date<=now 过滤——钳制到当前时刻前
        if withHour > Date() {
            withHour = Calendar.current.date(byAdding: .minute, value: -1, to: Date())!
        }
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        r.id = UUID()
        r.habitId = habit.id
        r.date = withHour
        r.isCompleted = completed
        r.value = value.map { NSNumber(value: $0) }
        r.isRetroactive = retroactive
        r.createdAt = withHour
        return r
    }

    private func buildData(for habits: [Habit], repo: HabitRepository) -> HabitProjectionData {
        let facts = repo.allRecordFacts()
        let windows = repo.pauseWindowsByIds(habits.map(\.id))
        return HabitPresentationProjector.buildData(records: facts, pauseWindowsByHabit: windows, now: Date())
    }

    func test_长廊批量成就与仓库连续口径一致_含今日撤回() throws {
        let (repo, context) = try makeRepo()
        var habits: [Habit] = []
        for frequency in [HabitFrequency.daily, .weekly, .monthly] {
            for bad in [false, true] {
                let habit = try makeHabit(in: context, frequency: frequency, isBadHabit: bad,
                                          targetCount: 2, createdAtDaysAgo: 40)
                for offset in [0, 1, 2, 3, 8, 9, 16, 17, 31, 32] {
                    try makeRecord(in: context, habit: habit, daysAgo: offset, hour: 0)
                }
                // 今日最后一条撤回：不能因更早一条为完成态而改变连续倒查起点。
                let cancellation = try makeRecord(in: context, habit: habit, daysAgo: 0, completed: false)
                cancellation.date = Date().addingTimeInterval(-1)
                habits.append(habit)
            }
        }
        try context.save()
        let snapshot = MemoryAchievementSnapshot(context: context)
        for habit in habits {
            XCTAssertEqual(snapshot.streaks[habit.id]?.value, repo.calculateStreakInfo(for: habit).value,
                           "批量读取不能改变连续成就的数值")
            XCTAssertEqual(snapshot.completedToday.contains(habit.id), repo.isTodayCompleted(for: habit))
        }
    }

    // MARK: - 记录 / 达标分离（R05）

    func test_计数一条记录算已记录但不算达标() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  targetValue: 8, unit: "杯")
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 1)
        try context.save()
        _ = repo

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertTrue(snapshot.today.isRecorded, "今天有记录（值1）应算已记录")
        XCTAssertFalse(snapshot.today.isTargetMet, "1 < 8 未达标")
    }

    func test_真实0是有效记录不是未记录() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  targetValue: 8, unit: "杯")
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 0)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertTrue(snapshot.today.isRecorded, "真实 0 是有效业务数据（方案 §9.1）")
        XCTAssertTrue(snapshot.trail.first { $0.isToday }?.isRecorded == true, "今天的格子已点亮")
    }

    func test_计数达标后独立标记() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  targetValue: 8, unit: "杯")
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 9, value: 3)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 14, value: 5)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertTrue(snapshot.today.isTargetMet, "3+5=8 达标")
        XCTAssertTrue(snapshot.today.isRecorded)
    }

    // MARK: - 痕迹去重（R18）

    func test_同日多次记录痕迹只计一天() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 9, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 10, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 11, value: 1)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        let recordedCount = snapshot.trail.filter(\.isRecorded).count
        XCTAssertEqual(recordedCount, 1, "同日多次记录在七天痕迹里只算一项")
    }

    // MARK: - 打卡连续与 repository 原口径对齐

    func test_打卡每日连续与repository一致() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        for daysAgo in 0..<6 {
            try makeRecord(in: context, habit: habit, daysAgo: daysAgo, completed: true)
        }
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let projected = HabitPresentationProjector.checkInStreakLabel(habit: habit, data: data)
        let repositoryStreak = repo.calculateStreakInfo(for: habit)

        XCTAssertEqual(projected.value, repositoryStreak.value,
                       "投影连续必须与 repository 原口径一致（判定基线）")
        XCTAssertEqual(projected.value, 6)
    }

    func test_打卡暂停冻结日不断不涨与repository一致() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        // 5 天连续 + 昨天/前天之间的冻结日（3 天前冻结）
        for daysAgo in [0, 1, 2] {
            try makeRecord(in: context, habit: habit, daysAgo: daysAgo, completed: true)
        }
        // 3 天前冻结整天
        let frozenDay = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
        habit.pauseWindows = [HabitPauseWindow(startDate: frozenDay, endDate: frozenDay)]
        for daysAgo in [4, 5] {
            try makeRecord(in: context, habit: habit, daysAgo: daysAgo, completed: true)
        }
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let projected = HabitPresentationProjector.checkInStreakLabel(habit: habit, data: data)
        let repositoryStreak = repo.calculateStreakInfo(for: habit)

        XCTAssertEqual(projected.value, repositoryStreak.value,
                       "冻结日不算断不涨，两口径一致")
        XCTAssertEqual(projected.value, 5, "3+2，冻结日跳过")
    }

    func test_坏习惯打卡连续控制与repository一致() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, isBadHabit: true, createdAtDaysAgo: 30)
        // 昨天「发生」了一次，其余天控制住
        try makeRecord(in: context, habit: habit, daysAgo: 1, completed: true)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let projected = HabitPresentationProjector.checkInControlStreak(habit: habit, data: data)
        let repositoryStreak = repo.calculateStreak(for: habit)

        XCTAssertEqual(projected, repositoryStreak, "坏习惯连续控制与原口径一致")
    }

    // MARK: - 数值连续（R23，新只读口径）

    func test_数值每日连续中断即断() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 1, value: 1)
        // 2 天前无记录
        try makeRecord(in: context, habit: habit, daysAgo: 3, value: 1)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let streak = HabitPresentationProjector.numericStreakLabel(habit: habit, data: data)

        XCTAssertEqual(streak?.value, 2)
        XCTAssertEqual(streak?.kindName, String(localized: "连续记录"))
    }

    func test_数值每日连续冻结空日跳过不断() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 1, value: 1)
        // 2 天前冻结（无记录）
        let frozenDay = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!
        habit.pauseWindows = [HabitPauseWindow(startDate: frozenDay, endDate: frozenDay)]
        try makeRecord(in: context, habit: habit, daysAgo: 3, value: 1)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let streak = HabitPresentationProjector.numericStreakLabel(habit: habit, data: data)

        XCTAssertEqual(streak?.value, 3, "3 天记录，冻结空日跳过不断开")
    }

    func test_数值每日今天未记录从昨天倒查() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 1, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 2, value: 1)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let streak = HabitPresentationProjector.numericStreakLabel(habit: habit, data: data)

        XCTAssertEqual(streak?.value, 2, "今天未记录从昨天开始倒查")
    }

    func test_数值周期连续当前未达标不早断() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  frequency: .weekly, targetValue: 3, createdAtDaysAgo: 30)
        // 本周只记 1 次（未达标），上周记 3 次（达标）——上周日期按日历精确计算
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!)!
        for offset in 0..<3 {
            let day = calendar.date(byAdding: .day, value: offset, to: lastWeekStart)!
            // 直接补写上周记录
            let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
            r.id = UUID()
            r.habitId = habit.id
            r.date = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
            r.isCompleted = false
            r.value = NSNumber(value: 1)
            r.createdAt = r.date
        }
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let streak = HabitPresentationProjector.numericStreakLabel(habit: habit, data: data)

        XCTAssertEqual(streak?.value, 1, "当前周期未达标不立即截断，显示上一完整周期积累")
        XCTAssertEqual(streak?.unitName, String(localized: "周"))
        XCTAssertEqual(streak?.kindName, String(localized: "连续达标"))
    }

    func test_数值坏习惯不出连续() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  isBadHabit: true, targetValue: 2, createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 0, value: 1)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let streak = HabitPresentationProjector.streakLabel(for: habit, data: data)

        XCTAssertNil(streak, "数值坏习惯不新增『记录越多越好』的连续（方案 §9.4）")
    }

    // MARK: - 滚动七天

    func test_滚动七天含今天不含未来() {
        let calendar = Calendar.current
        let now = Date()
        let data = HabitProjectionData(
            recordsByHabit: [:], completedDaysByHabit: [:], dailyNumericByHabit: [:],
            pauseWindowsByHabit: [:], now: now, calendar: calendar
        )
        let days = HabitPresentationProjector.rollingSevenDays(data)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.startOfDay(for: days.last!), calendar.startOfDay(for: now), "末位是今天")
        XCTAssertEqual(calendar.startOfDay(for: days.first!),
                       calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!,
                       "首位是今天−6")
    }

    // MARK: - 当月缝线痕迹（月初累加视角，2026-10-07 东林定稿）

    private func monthDayCount(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: date)!.count
    }

    func test_当月窗口从1号到月末含未来() {
        let calendar = Calendar.current
        let now = Date()
        let data = HabitProjectionData(
            recordsByHabit: [:], completedDaysByHabit: [:], dailyNumericByHabit: [:],
            pauseWindowsByHabit: [:], now: now, calendar: calendar
        )
        let days = HabitPresentationProjector.currentMonthDays(data)
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

        XCTAssertEqual(days.count, monthDayCount(now, calendar), "窗口是当月全部天数（10月=31格）")
        XCTAssertEqual(calendar.startOfDay(for: days.first!), monthStart, "首位是当月 1 号")
        XCTAssertEqual(days.last!,
                       calendar.date(byAdding: .day, value: monthDayCount(now, calendar) - 1, to: monthStart)!,
                       "末位是当月最后一天（含未来日子）")
        XCTAssertEqual(days.filter { $0 > today }.count,
                       monthDayCount(now, calendar) - (calendar.component(.day, from: today)),
                       "未来日子=月末减今天")
    }

    func test_行痕迹为当月且携带五态标记() throws {
        let (repo, context) = try makeRepo()
        // 10 天前创建 → 本月内创建日之前的日子是创建前空位（若创建日跨月则本月无空位）
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 10)
        try makeRecord(in: context, habit: habit, daysAgo: 0, completed: true)
        try makeRecord(in: context, habit: habit, daysAgo: 2, completed: true, retroactive: true)
        try context.save()
        // 暂停窗口：5 天前 → 昨天（覆盖昨天，今天不暂停）
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let fiveDaysAgo = calendar.date(byAdding: .day, value: -5, to: dayStart)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart)!
        habit.pauseWindows = [HabitPauseWindow(startDate: fiveDaysAgo, endDate: yesterday)]
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertEqual(snapshot.trail.count, monthDayCount(Date(), calendar), "缝线痕迹是当月全部天数")
        let today = snapshot.trail.first { $0.isToday }
        XCTAssertNotNil(today, "今天带指针")
        XCTAssertTrue(today?.isRecorded == true, "今天已打卡")
        XCTAssertFalse(today?.isFuture ?? true, "今天不是未来")
        let retroDay = snapshot.trail.first { $0.isRetroactive }
        XCTAssertNotNil(retroDay, "补录日进痕迹")
        XCTAssertTrue(retroDay?.isRecorded == true, "补录日同时是已记录（空心针数据源）")
        let pausedDays = snapshot.trail.filter(\.isPaused)
        XCTAssertFalse(pausedDays.isEmpty, "暂停窗口内的日子带暂停标记")
        XCTAssertTrue(pausedDays.contains { $0.isRecorded }, "暂停窗口内的补录日：记录事实不被暂停抹除（渲染时记录优先于搭线）")
        let creationDay = calendar.startOfDay(for: habit.createdAt)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: dayStart))!
        let expectedBeforeCreation = creationDay >= monthStart
            ? calendar.dateComponents([.day], from: monthStart, to: creationDay).day!
            : 0
        let beforeCreation = snapshot.trail.filter(\.isBeforeCreation)
        XCTAssertEqual(beforeCreation.count, expectedBeforeCreation, "创建前的日子是空位（按当月内实际天数算）")
        XCTAssertTrue(beforeCreation.allSatisfy { !$0.isRecorded && !$0.isPaused && !$0.isFuture }, "创建前不可能有记录、也谈不上暂停或未来")
        let futureDays = snapshot.trail.filter(\.isFuture)
        XCTAssertEqual(futureDays.count,
                       monthDayCount(Date(), calendar) - calendar.component(.day, from: dayStart),
                       "今天之后的月末日子全带未来标记")
        XCTAssertTrue(futureDays.allSatisfy { !$0.isRecorded && !$0.isRetroactive && !$0.isPaused }, "未来日子无记录无暂停")
    }

    func test_创建满30天时当月窗口内无空位() throws {
        let (repo, context) = try makeRepo()
        // 30 天前创建 → 创建日必落在当月 1 号或更早，本月窗口内没有创建前空位
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertTrue(snapshot.trail.allSatisfy { !$0.isBeforeCreation }, "创建满 30 天时当月窗口内无空位")
    }

    // MARK: - 坏习惯超标标记

    func test_坏习惯数值超标日标记() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum,
                                  isBadHabit: true, targetValue: 2, unit: "杯", createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 9, value: 1)
        try makeRecord(in: context, habit: habit, daysAgo: 0, hour: 15, value: 2)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.daySnapshot(habit: habit, day: Date(), data: data)

        XCTAssertEqual(snapshot.numericValue, 3, "当日 SUM = 3")
        XCTAssertTrue(snapshot.isOverLimit, "3 > 控制目标 2 超标")
        XCTAssertTrue(snapshot.isRecorded)
    }

    // MARK: - 补录资格（R27/R28 策略）

    func test_补签窗口边界() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        try context.save()
        let data = buildData(for: [habit], repo: repo)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for offset in [-1, -6] {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            XCTAssertEqual(HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data),
                           .sign, "今天\(offset) 天在补签窗口内")
        }
        // 今天/未来不可补；−7 已出补签窗口但仍在补记范围（方案 §10.1）
        let todayDay = calendar.date(byAdding: .day, value: 0, to: today)!
        XCTAssertNil(HabitPresentationProjector.retroactiveMode(habit: habit, day: todayDay, data: data), "今天不可补")
        let futureDay = calendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertNil(HabitPresentationProjector.retroactiveMode(habit: habit, day: futureDay, data: data), "未来不可补")
        let day7 = calendar.date(byAdding: .day, value: -7, to: today)!
        XCTAssertEqual(HabitPresentationProjector.retroactiveMode(habit: habit, day: day7, data: data),
                       .backfill, "−7 出补签窗口，但作为补记历史仍允许")
    }

    func test_创建前不可补录() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 3)
        try context.save()
        let data = buildData(for: [habit], repo: repo)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: Date()))!

        XCTAssertNil(HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data),
                     "习惯创建前的日期无资格补录")
    }

    func test_已完成日不再给补签资格() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        try makeRecord(in: context, habit: habit, daysAgo: 1, completed: true)
        try context.save()
        let data = buildData(for: [habit], repo: repo)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!

        XCTAssertNil(HabitPresentationProjector.retroactiveMode(habit: habit, day: day, data: data),
                     "已完成日幂等，无需补签")
    }

    /// 2026-10-17 东林实报：周频率习惯真实做了忘记录，同样必须可补（与每日习惯同一套资格）
    func test_周频率打卡漏做日可补签_窗口外走补记() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .checkIn, frequency: .weekly,
                                  targetCount: 3, createdAtDaysAgo: 30)
        try context.save()
        let data = buildData(for: [habit], repo: repo)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(HabitPresentationProjector.retroactiveMode(habit: habit, day: yesterday, data: data),
                       .sign, "周频率漏做日在补签窗口内 = 补签")
        let day8 = calendar.date(byAdding: .day, value: -8, to: today)!
        XCTAssertEqual(HabitPresentationProjector.retroactiveMode(habit: habit, day: day8, data: data),
                       .backfill, "窗口外历史日 = 补记")

        // 已完成日同样幂等
        try makeRecord(in: context, habit: habit, daysAgo: 2, completed: true)
        try context.save()
        let data2 = buildData(for: [habit], repo: repo)
        let day2 = calendar.date(byAdding: .day, value: -2, to: today)!
        XCTAssertNil(HabitPresentationProjector.retroactiveMode(habit: habit, day: day2, data: data2),
                     "周频率已完成日幂等，无需补签")
    }

    // MARK: - 每日结算时间（日界平移；固定时刻，不依赖跑测试的钟点）

    private func fixedDate(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func fixedDay(_ day: Int, month: Int = 10) -> Date { fixedDate(day, 0, month: month) }

    /// 结算 4:00 的归属函数：凌晨 0:00–3:59 归前一天，4:00 起归当天；默认 0:00 为恒等
    func test_结算时间_真实时刻归属日() {
        let calendar = Calendar.current
        let fourAM = 4 * 60
        XCTAssertEqual(HabitDayAttribution.attributedDay(fixedDate(20, 1), dayEndMinutes: fourAM, calendar: calendar), fixedDay(19))
        XCTAssertEqual(HabitDayAttribution.attributedDay(fixedDate(20, 3, 59), dayEndMinutes: fourAM, calendar: calendar), fixedDay(19))
        XCTAssertEqual(HabitDayAttribution.attributedDay(fixedDate(20, 4), dayEndMinutes: fourAM, calendar: calendar), fixedDay(20))
        XCTAssertEqual(HabitDayAttribution.attributedDay(fixedDate(20, 23, 30), dayEndMinutes: fourAM, calendar: calendar), fixedDay(20))
        XCTAssertEqual(HabitDayAttribution.attributedDay(fixedDate(20, 1), dayEndMinutes: 0, calendar: calendar), fixedDay(20),
                       "默认结算 0:00 = 自然日，归属函数恒等")
    }

    /// 补签记录与整日坐标记录是「日坐标」，不随结算时间平移；只有实时打卡记录平移
    func test_结算时间_补签与整日记录不平移() {
        let calendar = Calendar.current
        let fourAM = 4 * 60
        let retro = HabitDayAttribution.attributedMoment(
            recordDate: fixedDay(19), isRetroactive: true, dayEndMinutes: fourAM, calendar: calendar)
        XCTAssertEqual(retro, fixedDay(19), "补签记录 date=目标日零点，平移会把它推到前一天")
        let midnightExact = HabitDayAttribution.attributedMoment(
            recordDate: fixedDay(19), isRetroactive: false, dayEndMinutes: fourAM, calendar: calendar)
        XCTAssertEqual(midnightExact, fixedDay(19), "恰在零点的整日坐标记录（种子/导入）按日坐标原样")
        let live = HabitDayAttribution.attributedMoment(
            recordDate: fixedDate(20, 0, 30), isRetroactive: false, dayEndMinutes: fourAM, calendar: calendar)
        XCTAssertEqual(live, fixedDate(19, 20, 30), "实时记录向前平移结算时长")
    }

    /// SQL 超集窗口：归属到 19 日的实时记录最晚可写到 20 日 4:00
    func test_结算时间_超集查询窗口() {
        let window = HabitDayAttribution.rawFetchWindow(
            firstDay: fixedDay(19), lastDay: fixedDay(19), dayEndMinutes: 4 * 60, calendar: .current)
        XCTAssertEqual(window.start, fixedDay(19))
        XCTAssertEqual(window.end, fixedDate(20, 4))
    }

    /// 投影底座按各习惯的结算时间平移 fact：同一条凌晨记录，结算 4:00 的习惯归前一天，默认习惯归当天；
    /// 平移后 recordedAt 仍是真实时刻（展示用）
    func test_结算时间_投影底座按习惯平移记录() {
        let night = UUID()   // 结算 4:00
        let plain = UUID()   // 默认
        let at0030 = fixedDate(20, 0, 30)
        let facts = [night, plain].map {
            HabitRecordFact(id: UUID(), habitId: $0, date: at0030, isCompleted: true, value: nil, isRetroactive: false)
        }
        let now = fixedDate(20, 2)
        let data = HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:], dayEndMinutesByHabit: [night: 240], now: now)

        XCTAssertEqual(data.completedDaysByHabit[night], [fixedDay(19)])
        XCTAssertEqual(data.completedDaysByHabit[plain], [fixedDay(20)])
        XCTAssertEqual(data.recordsByHabit[night]?.first?.date, fixedDate(19, 20, 30))
        XCTAssertEqual(data.recordsByHabit[night]?.first?.recordedAt, at0030, "真实记录时刻保留给展示")
        XCTAssertEqual(data.today(for: night), fixedDay(19), "凌晨 2 点，结算 4:00 的习惯仍在 19 日")
        XCTAssertEqual(data.today(for: plain), fixedDay(20))
    }

    /// 核心场景：睡前习惯拖过零点。17 日 23:30 打卡、19 日 0:30 打卡（意图是 18 日的），
    /// 19 日凌晨 2 点看连续：结算 4:00 → 17、18 两天连上 = 2；默认结算 → 0:30 算 19 日、18 日空档，只剩今天 1 天
    func test_结算时间_凌晨打卡不断连续() throws {
        let (_, context) = try makeRepo()
        let nightHabit = try makeHabit(in: context)
        let plainHabit = try makeHabit(in: context)
        nightHabit.dayEndTime = (hour: 4, minute: 0)
        for habit in [nightHabit, plainHabit] {
            habit.createdAt = fixedDay(1)
        }
        try context.save()

        var facts: [HabitRecordFact] = []
        for habit in [nightHabit, plainHabit] {
            for moment in [fixedDate(17, 23, 30), fixedDate(19, 0, 30)] {
                facts.append(HabitRecordFact(id: UUID(), habitId: habit.id, date: moment,
                                             isCompleted: true, value: nil, isRetroactive: false))
            }
        }
        let now = fixedDate(19, 2)
        let data = HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [nightHabit.id: nightHabit.dayEndMinutes], now: now)

        XCTAssertEqual(HabitPresentationProjector.checkInStreakLabel(habit: nightHabit, data: data).value, 2)
        XCTAssertEqual(HabitPresentationProjector.checkInStreakLabel(habit: plainHabit, data: data).value, 1)
    }

    /// 结算点之后看「今天」：凌晨的记录已归前一天，今天尚未记录；默认习惯则算今天已记录
    func test_结算时间_行快照今日状态按习惯口径() throws {
        let (_, context) = try makeRepo()
        let nightHabit = try makeHabit(in: context)
        let plainHabit = try makeHabit(in: context)
        nightHabit.dayEndTime = (hour: 4, minute: 0)
        for habit in [nightHabit, plainHabit] {
            habit.createdAt = fixedDay(1)
        }
        try context.save()

        let facts = [nightHabit, plainHabit].map {
            HabitRecordFact(id: UUID(), habitId: $0.id, date: fixedDate(20, 0, 30),
                            isCompleted: true, value: nil, isRetroactive: false)
        }
        let data = HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [nightHabit.id: nightHabit.dayEndMinutes], now: fixedDate(20, 5))

        let nightRow = HabitPresentationProjector.rowSnapshot(habit: nightHabit, lifecycle: .active, data: data)
        let plainRow = HabitPresentationProjector.rowSnapshot(habit: plainHabit, lifecycle: .active, data: data)
        XCTAssertFalse(nightRow.today.isCheckInDone, "5 点已过结算，0:30 的记录属 19 日，20 日尚未打卡")
        XCTAssertTrue(plainRow.today.isCheckInDone)
        XCTAssertEqual(nightRow.trail.first { $0.isToday }?.day, fixedDay(20))
        XCTAssertTrue(nightRow.trail.first { $0.day == fixedDay(19) }?.isRecorded ?? false)

        // 结算点之前（凌晨 2 点）：习惯的「今天」还是 19 日，trail 的今日指针也指 19 日
        let early = HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [nightHabit.id: nightHabit.dayEndMinutes], now: fixedDate(20, 2))
        let earlyRow = HabitPresentationProjector.rowSnapshot(habit: nightHabit, lifecycle: .active, data: early)
        XCTAssertTrue(earlyRow.today.isCheckInDone)
        XCTAssertEqual(earlyRow.trail.first { $0.isToday }?.day, fixedDay(19))
    }

    /// 回顾快照：范围与「今天/未来」按习惯口径展开
    func test_结算时间_回顾快照范围与今日按习惯口径() throws {
        let (_, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        habit.dayEndTime = (hour: 4, minute: 0)
        habit.createdAt = fixedDay(1)
        try context.save()

        let facts = [HabitRecordFact(id: UUID(), habitId: habit.id, date: fixedDate(20, 0, 30),
                                     isCompleted: true, value: nil, isRetroactive: false)]
        let now = fixedDate(20, 2)
        let data = HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [habit.id: habit.dayEndMinutes], now: now)
        let info = HabitReviewHabitInfo(habit: habit, lifecycle: .active)
        let snapshot = HabitReviewProjector.rangeSnapshot(info: info, range: .lastDays(1), data: data)

        XCTAssertEqual(snapshot.dayEndMinutes, 240)
        XCTAssertEqual(snapshot.interval, DateInterval(start: fixedDay(19), end: fixedDay(20)),
                       "最近 1 天 = 习惯口径的今天（19 日）")
        XCTAssertTrue(snapshot.day(fixedDay(19), today: now, calendar: .current).isRecorded)
        XCTAssertFalse(snapshot.day(fixedDay(19), today: now, calendar: .current).isFuture)
        XCTAssertTrue(snapshot.day(fixedDay(20), today: now, calendar: .current).isFuture,
                      "凌晨 2 点，20 日对这个习惯还没开始")
    }
}
