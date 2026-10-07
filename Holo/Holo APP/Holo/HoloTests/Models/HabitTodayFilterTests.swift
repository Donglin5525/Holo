//
//  HabitTodayFilterTests.swift
//  HoloTests
//
//  2026-10-07 今天页「全部/未记录」筛选回归（东林实报点击不生效）：
//  「未记录」进入时只固定当时还没记录的集合；本次记录的原位保留；
//  离开再进按当下重算。历史坑：旧实现把全部行收进集合 = 筛选恒等于全部。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HabitTodayFilterTests: XCTestCase {

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?

    private func makeStack() throws -> HabitRepository {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitFilterTest", managedObjectModel: model)
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
        return repository
    }

    private func makeHabit(in context: NSManagedObjectContext, name: String) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = name
        habit.icon = "drop.fill"
        habit.color = "#3B76C9"
        habit.type = HabitType.checkIn.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
        return habit
    }

    private func seedCheckIn(in context: NSManagedObjectContext, habitId: UUID, date: Date) throws {
        let record = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        record.id = UUID()
        record.habitId = habitId
        record.date = date
        record.isCompleted = true
        record.isRetroactive = false
    }

    func test_未记录筛选_只留进入时未记录的习惯_原位保留_重进重算() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let recorded = try makeHabit(in: context, name: "已记录习惯")
        let pending = try makeHabit(in: context, name: "未记录习惯")
        try seedCheckIn(in: context, habitId: recorded.id, date: Date())
        try context.save()
        repo.setup()

        let model = HabitModuleViewModel(repository: repo)
        // iOS 26.3 hosted XCTest 坑（在档）：局部 ObservableObject 测试结束销毁触发
        // malloc 非法释放——VM 与栈对象一并 retain 到进程结束
        CoreDataTestSupport.retain(model)
        XCTAssertEqual(model.filteredTodayRows.count, 2, "默认「全部」不筛")

        model.todayFilter = .unrecorded
        XCTAssertEqual(model.filteredTodayRows.map(\.name), ["未记录习惯"],
                       "「未记录」只留进入时还没记录的习惯，已记录行不得出现")

        // 固定集合语义：筛选不动，本次记录成功的行原位保留变成已记录
        try seedCheckIn(in: context, habitId: pending.id, date: Date())
        try context.save()
        model.refresh()
        XCTAssertEqual(model.filteredTodayRows.map(\.name), ["未记录习惯"],
                       "筛选中记录成功，该行原位保留")

        // 离开再进：集合按当下重算，全部已记录 → 空（空态接管）
        model.todayFilter = .all
        XCTAssertEqual(model.filteredTodayRows.count, 2)
        model.todayFilter = .unrecorded
        XCTAssertTrue(model.filteredTodayRows.isEmpty, "重进筛选按当下重算")
    }
}
