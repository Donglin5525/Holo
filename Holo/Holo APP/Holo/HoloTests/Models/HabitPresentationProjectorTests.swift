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
        XCTAssertEqual(snapshot.trail.last?.isRecorded, true)
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

    // MARK: - 三十天缝线痕迹（B 方案，2026-10-07）

    func test_滚动三十天含今天不含未来() {
        let calendar = Calendar.current
        let now = Date()
        let data = HabitProjectionData(
            recordsByHabit: [:], completedDaysByHabit: [:], dailyNumericByHabit: [:],
            pauseWindowsByHabit: [:], now: now, calendar: calendar
        )
        let days = HabitPresentationProjector.rollingThirtyDays(data)

        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(calendar.startOfDay(for: days.last!), calendar.startOfDay(for: now), "末位是今天")
        XCTAssertEqual(calendar.startOfDay(for: days.first!),
                       calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!,
                       "首位是今天−29")
    }

    func test_行痕迹扩到三十天且携带四态标记() throws {
        let (repo, context) = try makeRepo()
        // 10 天前创建 → 30 天窗口前 20 天是创建前空位
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 10)
        try makeRecord(in: context, habit: habit, daysAgo: 0, completed: true)
        try makeRecord(in: context, habit: habit, daysAgo: 2, completed: true, retroactive: true)
        try context.save()
        // 暂停窗口：5 天前 → 昨天（覆盖昨天，今天不暂停）
        let dayStart = Calendar.current.startOfDay(for: Date())
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: dayStart)!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        habit.pauseWindows = [HabitPauseWindow(startDate: fiveDaysAgo, endDate: yesterday)]
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertEqual(snapshot.trail.count, 30, "缝线痕迹固定三十天")
        let today = snapshot.trail.last!
        XCTAssertTrue(today.isToday, "末位是今天指针")
        XCTAssertTrue(today.isRecorded, "今天已打卡")
        let retroDay = snapshot.trail.first { $0.isRetroactive }
        XCTAssertNotNil(retroDay, "补录日进痕迹")
        XCTAssertTrue(retroDay?.isRecorded == true, "补录日同时是已记录（空心针数据源）")
        let pausedDays = snapshot.trail.filter(\.isPaused)
        XCTAssertFalse(pausedDays.isEmpty, "暂停窗口内的日子带暂停标记")
        XCTAssertTrue(pausedDays.contains { $0.isRecorded }, "暂停窗口内的补录日：记录事实不被暂停抹除（渲染时记录优先于搭线）")
        let beforeCreation = snapshot.trail.filter(\.isBeforeCreation)
        XCTAssertEqual(beforeCreation.count, 19, "创建前的日子是空位（10 天前创建：窗口 idx0..18 共 19 天）")
        XCTAssertTrue(beforeCreation.allSatisfy { !$0.isRecorded && !$0.isPaused }, "创建前不可能有记录、也谈不上暂停")
        // 四态互斥校验：今天既是指针又有记录，创建前空位不带记录/暂停
        XCTAssertTrue(today.isToday && today.isRecorded, "针脚与指针可叠加")
    }

    func test_创建前空位不吞掉真实记录窗口() throws {
        let (repo, context) = try makeRepo()
        // 30 天前创建 → 窗口内没有创建前空位
        let habit = try makeHabit(in: context, type: .checkIn, createdAtDaysAgo: 30)
        try context.save()

        let data = buildData(for: [habit], repo: repo)
        let snapshot = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)

        XCTAssertTrue(snapshot.trail.allSatisfy { !$0.isBeforeCreation }, "创建满 30 天时窗口内无空位")
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
}
