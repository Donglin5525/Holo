//
//  HabitOverLimitHintTests.swift
//  HoloTests
//
//  2026-10-07 坏习惯超限提示恢复（交互重构 V1 未移植的回归）：
//  投影层 HabitTodayProgress.isOverLimit 口径 + 记录成功后的警告条路由
//  （旧磁贴版「已超当日限额」提示的 V1 接续，形态=底部反馈条警告态）。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HabitOverLimitHintTests: XCTestCase {

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?

    @discardableResult
    private func makeStack() throws -> HabitRepository {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitOverLimitTest", managedObjectModel: model)
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

    @discardableResult
    private func makeNumericHabit(in context: NSManagedObjectContext, name: String,
                                   isBadHabit: Bool, targetValue: Double?) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = name
        habit.icon = "drop.fill"
        habit.color = "#3B76C9"
        habit.type = HabitType.numeric.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
        habit.targetValue = targetValue.map { NSNumber(value: $0) }
        return habit
    }

    @discardableResult
    private func seedNumericRecord(in context: NSManagedObjectContext, habitId: UUID,
                                   value: Double) throws -> HabitRecord {
        let record = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        record.id = UUID()
        record.habitId = habitId
        record.date = Date()
        record.isCompleted = true
        record.isRetroactive = false
        record.value = NSNumber(value: value)
        return record
    }

    // MARK: 投影口径

    func test_投影_坏习惯计数当日聚合超上限_isOverLimit为真() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let habit = try makeNumericHabit(in: context, name: "抽烟", isBadHabit: true, targetValue: 3)
        try seedNumericRecord(in: context, habitId: habit.id, value: 2)
        try seedNumericRecord(in: context, habitId: habit.id, value: 2)
        try context.save()
        repo.setup()

        let data = HabitPresentationProjector.buildData(
            records: try repo.tryAllRecordFacts(),
            pauseWindowsByHabit: [:],
            now: Date(),
            calendar: Calendar.current
        )
        let row = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)
        XCTAssertTrue(row.today.isOverLimit, "SUM=4 > 上限 3 应超限")
        XCTAssertEqual(row.today.todayValue, 4)
    }

    func test_投影_等于上限不超限_好习惯超目标不误报() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let bad = try makeNumericHabit(in: context, name: "抽烟", isBadHabit: true, targetValue: 3)
        try seedNumericRecord(in: context, habitId: bad.id, value: 3)
        let good = try makeNumericHabit(in: context, name: "喝水", isBadHabit: false, targetValue: 8)
        try seedNumericRecord(in: context, habitId: good.id, value: 10)
        try context.save()
        repo.setup()

        let data = HabitPresentationProjector.buildData(
            records: try repo.tryAllRecordFacts(),
            pauseWindowsByHabit: [:],
            now: Date(),
            calendar: Calendar.current
        )
        let badRow = HabitPresentationProjector.rowSnapshot(habit: bad, lifecycle: .active, data: data)
        XCTAssertEqual(badRow.today.todayValue, 3)
        XCTAssertFalse(badRow.today.isOverLimit, "等于上限不超（口径为 >）")
        let goodRow = HabitPresentationProjector.rowSnapshot(habit: good, lifecycle: .active, data: data)
        XCTAssertFalse(goodRow.today.isOverLimit, "好习惯超目标是达成，语义相反不触发")
    }

    func test_投影_无目标坏习惯不超限() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let habit = try makeNumericHabit(in: context, name: "熬夜", isBadHabit: true, targetValue: nil)
        try seedNumericRecord(in: context, habitId: habit.id, value: 99)
        try context.save()
        repo.setup()

        let data = HabitPresentationProjector.buildData(
            records: try repo.tryAllRecordFacts(),
            pauseWindowsByHabit: [:],
            now: Date(),
            calendar: Calendar.current
        )
        let row = HabitPresentationProjector.rowSnapshot(habit: habit, lifecycle: .active, data: data)
        XCTAssertFalse(row.today.isOverLimit, "未设上限不判定超限")
    }

    // MARK: 记录后警告条路由（VM 全链）

    func test_记录路由_超上限弹警告形态_未超弹普通形态() async throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let bad = try makeNumericHabit(in: context, name: "抽烟", isBadHabit: true, targetValue: 3)
        let good = try makeNumericHabit(in: context, name: "喝水", isBadHabit: false, targetValue: 8)
        try context.save()
        repo.setup()

        let model = HabitModuleViewModel(
            repository: repo,
            coordinator: HabitActionCoordinator(repository: repo)
        )

        // 坏习惯记到上限内（3）：普通「已记录」形态
        for _ in 0..<3 {
            await model.record(kind: .increment(amount: 1), habitId: bad.id)
        }
        XCTAssertEqual(model.undoHint?.style, .recorded, "SUM=3 未超上限应普通形态")

        // 第 4 次超限：警告形态
        await model.record(kind: .increment(amount: 1), habitId: bad.id)
        XCTAssertEqual(model.undoHint?.style, .overLimit, "SUM=4 > 上限 3 应警告形态")
        XCTAssertEqual(model.undoHint?.text, String(localized: "已超当日限额，请注意控制"))

        // 好习惯超过目标值：不误报警告
        for _ in 0..<9 {
            await model.record(kind: .increment(amount: 1), habitId: good.id)
        }
        XCTAssertEqual(model.undoHint?.style, .recorded, "好习惯超目标不触发警告")

        // 行内超限状态随投影刷新
        let badRow = model.todayRows.first { $0.id == bad.id }
        XCTAssertTrue(badRow?.today.isOverLimit == true)
    }
}
