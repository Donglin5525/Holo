//
//  HighlightDetectorBatchTests.swift
//  HoloTests
//
//  高亮检测器批量化重构的语义锁定测试：
//  消费异常（>7日均值×1.5）/ 习惯全勤日 / 重要任务完成（priority ≥ high）
//  三类检测此前为逐日 N+1 查询，重构为窗口级批量列查询 + 内存分组，
//  本测试钉住批量口径与原逐日口径的等价语义。
//

import XCTest
import CoreData
@testable import Holo

final class HighlightDetectorBatchTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(
            context, ["Transaction", "Habit", "HabitRecord", "TodoTask"]
        )
    }

    override func tearDown() {
        context = nil
    }

    // MARK: - Helpers

    private func dayStart(_ daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return calendar.startOfDay(for: day)
    }

    /// 当天正午时间（避开 startOfDay 边界）
    private func noon(_ daysAgo: Int) -> Date {
        dayStart(daysAgo).addingTimeInterval(12 * 3600)
    }

    @discardableResult
    private func addExpense(_ amount: Double, date: Date) throws -> Transaction {
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: context) as! Transaction
        tx.id = UUID()
        tx.date = date
        tx.amount = NSDecimalNumber(value: amount)
        tx.type = TransactionType.expense.rawValue
        tx.note = nil
        tx.isReconciliationAdjustment = false
        try context.save()
        return tx
    }

    @discardableResult
    private func addHabit(name: String = "晨间阅读") throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = name
        habit.icon = "book.fill"
        habit.color = "#3B82F6"
        habit.type = HabitType.checkIn.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
        try context.save()
        return habit
    }

    @discardableResult
    private func addHabitRecord(habitId: UUID, date: Date, completed: Bool = true) throws -> HabitRecord {
        let record = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        record.id = UUID()
        record.habitId = habitId
        record.date = date
        record.isCompleted = completed
        record.createdAt = date
        try context.save()
        return record
    }

    @discardableResult
    private func addTask(
        title: String,
        priority: Int16,
        completedAt date: Date?
    ) throws -> TodoTask {
        let task = NSEntityDescription.insertNewObject(forEntityName: "TodoTask", into: context) as! TodoTask
        task.id = UUID()
        task.title = title
        task.priority = priority
        task.completed = date != nil
        task.completedAt = date
        task.archived = false
        task.createdAt = Date()
        try context.save()
        return task
    }

    private func categories(on day: Date) -> [HighlightCategory] {
        let calendar = Calendar.current
        let key = calendar.startOfDay(for: day)
        let results = HighlightDetector.detectBatch(for: [day], context: context)
        return (results[key] ?? []).map(\.category)
    }

    // MARK: - 消费异常

    func test_消费异常_当日高于7日均值1_5倍检出() throws {
        // 前 7 天每天 ¥10（均值 ¥10），今天 ¥20（2 倍）
        for offset in 1...7 {
            try addExpense(10, date: noon(offset))
        }
        try addExpense(20, date: noon(0))

        let categories = categories(on: dayStart(0))
        XCTAssertTrue(categories.contains(.spendingAnomaly), "当日支出 2 倍于日均应检出消费异常，实际：\(categories)")
    }

    func test_消费正常_低于1_5倍不检出() throws {
        for offset in 1...7 {
            try addExpense(10, date: noon(offset))
        }
        try addExpense(12, date: noon(0)) // 1.2 倍

        let categories = categories(on: dayStart(0))
        XCTAssertFalse(categories.contains(.spendingAnomaly), "1.2 倍不应触发，实际：\(categories)")
    }

    func test_对账调整流水不参与消费异常() throws {
        for offset in 1...7 {
            try addExpense(10, date: noon(offset))
        }
        // 今天仅一笔对账调整 ¥100（收支统计口径应排除）
        let tx = try addExpense(100, date: noon(0))
        tx.isReconciliationAdjustment = true
        try context.save()

        let categories = categories(on: dayStart(0))
        XCTAssertFalse(categories.contains(.spendingAnomaly), "对账调整不进消费口径，实际：\(categories)")
    }

    // MARK: - 习惯全勤日

    func test_习惯全勤_当日全部完成检出() throws {
        let habitA = try addHabit(name: "习惯A")
        let habitB = try addHabit(name: "习惯B")
        try addHabitRecord(habitId: habitA.id, date: noon(0))
        try addHabitRecord(habitId: habitB.id, date: noon(0))

        let categories = categories(on: dayStart(0))
        XCTAssertTrue(categories.contains(.habitPerfect), "两习惯当天全部完成应检出全勤日，实际：\(categories)")
    }

    func test_习惯未全勤_不检出() throws {
        let habitA = try addHabit(name: "习惯A")
        let habitB = try addHabit(name: "习惯B")
        try addHabitRecord(habitId: habitA.id, date: noon(0))
        // 习惯B 当天无记录

        let categories = categories(on: dayStart(0))
        XCTAssertFalse(categories.contains(.habitPerfect), "习惯B 未完成不应检出全勤日，实际：\(categories)")
    }

    func test_习惯未完成记录不算全勤() throws {
        let habit = try addHabit()
        try addHabitRecord(habitId: habit.id, date: noon(0), completed: false)

        let categories = categories(on: dayStart(0))
        XCTAssertFalse(categories.contains(.habitPerfect), "isCompleted == NO 的记录不算完成，实际：\(categories)")
    }

    // MARK: - 重要任务完成

    func test_重要任务_high优先级完成检出() throws {
        try addTask(title: "上线检查", priority: TaskPriority.high.rawValue, completedAt: noon(0))

        let categories = categories(on: dayStart(0))
        XCTAssertTrue(categories.contains(.taskCompletion), "high 优先级任务完成应检出，实际：\(categories)")
    }

    func test_普通任务_medium优先级不检出() throws {
        try addTask(title: "日常琐事", priority: TaskPriority.medium.rawValue, completedAt: noon(0))

        let categories = categories(on: dayStart(0))
        XCTAssertFalse(categories.contains(.taskCompletion), "medium 优先级不应检出，实际：\(categories)")
    }

    func test_紧急任务副题标注() throws {
        try addTask(title: "救火", priority: TaskPriority.urgent.rawValue, completedAt: noon(0))

        let calendar = Calendar.current
        let key = calendar.startOfDay(for: dayStart(0))
        let results = HighlightDetector.detectBatch(for: [dayStart(0)], context: context)
        let highlight = (results[key] ?? []).first { $0.category == .taskCompletion }
        XCTAssertEqual(highlight?.subtitle, "紧急任务", "urgent 优先级应带紧急副题")
    }

    // MARK: - 空数据与多日窗口

    func test_空库检测返回空() {
        let results = HighlightDetector.detectBatch(for: [dayStart(0), dayStart(1)], context: context)
        XCTAssertTrue(results.isEmpty)
    }

    func test_多日一次检测_各日独立判定() throws {
        // 均值分母恒为 7 天（原逐日语义）：造足 7 天基线 ¥10/天
        let habit = try addHabit()
        for offset in 2...8 {
            try addExpense(10, date: noon(offset))
        }
        // 昨天：基线消费 + 习惯全勤 → 消费正常、全勤检出
        try addExpense(10, date: noon(1))
        try addHabitRecord(habitId: habit.id, date: noon(1))
        // 今天：¥30（3 倍于日均 ¥10）+ 习惯缺勤 → 异常、无全勤
        try addExpense(30, date: noon(0))

        let results = HighlightDetector.detectBatch(
            for: [dayStart(0), dayStart(1)], context: context
        )
        let calendar = Calendar.current

        let todayKey = calendar.startOfDay(for: dayStart(0))
        XCTAssertTrue((results[todayKey] ?? []).contains { $0.category == .spendingAnomaly }, "今天 3 倍于日均应检出")
        XCTAssertFalse((results[todayKey] ?? []).contains { $0.category == .habitPerfect }, "今天习惯缺勤")

        let yesterdayKey = calendar.startOfDay(for: dayStart(1))
        XCTAssertTrue((results[yesterdayKey] ?? []).contains { $0.category == .habitPerfect }, "昨天全勤")
        XCTAssertFalse((results[yesterdayKey] ?? []).contains { $0.category == .spendingAnomaly }, "昨天等于日均不应检出")
    }
}
