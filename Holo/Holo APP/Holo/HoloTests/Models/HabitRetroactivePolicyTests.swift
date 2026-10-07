//
//  HabitRetroactivePolicyTests.swift
//  HoloTests
//
//  2026-10 重构补签/补记策略验证（方案 §10）：
//  幂等识别前移（已完成日不弹付费墙不扣额）、配额成功后才消费、
//  窗口边界、数值追加扣额、失败不扣额。
//

import XCTest
import CoreData
@testable import Holo

final class HabitRetroactivePolicyTests: XCTestCase {

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?
    private var repo: HabitRepository?

    private func makeRepo() throws -> (HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitRetroPolicyTest", managedObjectModel: model)
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
                           createdAtDaysAgo: Int = 60) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = "静心片刻"
        habit.icon = "sparkles"
        habit.color = "#3B76C9"
        habit.type = type.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = aggregation.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Calendar.current.date(byAdding: .day, value: -createdAtDaysAgo, to: Date())!
        habit.updatedAt = habit.createdAt
        return habit
    }

    private func setQuotaUsed(_ used: Int) {
        HabitRetroactiveQuota.reset()
        if used > 0 {
            for _ in 0..<used {
                HabitRetroactiveQuota.consume()
            }
        }
    }

    override func tearDown() {
        HabitRetroactiveQuota.reset()
        super.tearDown()
    }

    // MARK: - 幂等前移（R31）

    func test_免费用尽时已完成日幂等返回不弹付费墙() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        // 昨天已完成
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        r.id = UUID()
        r.habitId = habit.id
        r.date = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: yesterday)!
        r.isCompleted = true
        r.createdAt = r.date
        try context.save()

        setQuotaUsed(HabitRetroactivePolicy.freeMonthlyQuota) // 额度用尽

        let result = try repo.retroactiveCheckIn(for: habit, on: yesterday)
        guard case .alreadyCompleted = result else {
            return XCTFail("已完成日应幂等返回，实际 \(result)。配额门禁不得先于幂等识别（R31）")
        }
        XCTAssertEqual(HabitRetroactiveQuota.usedCount(), HabitRetroactivePolicy.freeMonthlyQuota, "不扣额")
    }

    func test_免费用尽时新写入返回requiresPlus() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        try context.save()
        setQuotaUsed(HabitRetroactivePolicy.freeMonthlyQuota)

        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let result = try repo.retroactiveCheckIn(for: habit, on: day)
        guard case .requiresPlus = result else {
            return XCTFail("额度用尽的新写入应要求 Plus，实际 \(result)")
        }
    }

    // MARK: - 配额消费时机（R32/R12）

    func test_成功后才扣额度() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        try context.save()
        setQuotaUsed(1)

        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        _ = try repo.retroactiveCheckIn(for: habit, on: day)
        XCTAssertEqual(HabitRetroactiveQuota.usedCount(), 2, "成功写入扣一次")
    }

    func test_写入失败不扣额度() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        try context.save()
        setQuotaUsed(0)

        // 注入 save 必败 context（挂同一 coordinator 保证 fetch/create 正常，仅 save 抛错）
        let failing = FailingSaveContext(concurrencyType: .mainQueueConcurrencyType)
        failing.persistentStoreCoordinator = context.persistentStoreCoordinator
        repo.context = failing
        // habit 也在同一 failing context 取实例（跨 context 关系才合法）
        let habitInFailing = try failing.existingObject(with: habit.objectID) as! Habit

        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        XCTAssertThrowsError(try repo.retroactiveCheckIn(for: habitInFailing, on: day), "save 失败应抛错")
        XCTAssertEqual(HabitRetroactiveQuota.usedCount(), 0, "失败绝不扣额（先打勾先扣额再回滚是红线）")
    }

    func test_数值补记追加成功扣一次() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum)
        try context.save()
        setQuotaUsed(0)

        // 数值型：已有记录的日子仍允许补记追加（真实历史）
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        r.id = UUID()
        r.habitId = habit.id
        r.date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        r.isCompleted = false
        r.value = NSNumber(value: 2)
        r.createdAt = r.date
        try context.save()

        let result = try repo.retroactiveCheckIn(for: habit, on: day, value: 3)
        guard case .success = result else {
            return XCTFail("数值追加是新的有效记录，应成功，实际 \(result)")
        }
        XCTAssertEqual(HabitRetroactiveQuota.usedCount(), 1, "追加成功扣一次")
    }

    // MARK: - 窗口与日期（R27/R28/R33）

    func test_补签窗口边界与仓库策略一致() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        try context.save()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // −6 可补（lookbackDays=7 含今天，实际可补过去 6 天）
        let day6 = calendar.date(byAdding: .day, value: -6, to: today)!
        let result6 = try repo.retroactiveCheckIn(for: habit, on: day6)
        guard case .success = result6 else { return XCTFail("−6 应可补") }

        // −7 不可补
        let day7 = calendar.date(byAdding: .day, value: -7, to: today)!
        let result7 = try repo.retroactiveCheckIn(for: habit, on: day7)
        guard case .invalidDate = result7 else { return XCTFail("−7 不可补签") }
    }

    func test_今天不可补签() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context)
        try context.save()

        let result = try repo.retroactiveCheckIn(for: habit, on: Date())
        guard case .invalidDate = result else { return XCTFail("今天请直接打卡") }
    }

    func test_创建前不可补() throws {
        let (repo, context) = try makeRepo()
        let habit = try makeHabit(in: context, createdAtDaysAgo: 3)
        try context.save()

        let day = Calendar.current.date(byAdding: .day, value: -5, to: Calendar.current.startOfDay(for: Date()))!
        let result = try repo.retroactiveCheckIn(for: habit, on: day)
        guard case .invalidDate = result else { return XCTFail("创建前无资格") }
    }
}

