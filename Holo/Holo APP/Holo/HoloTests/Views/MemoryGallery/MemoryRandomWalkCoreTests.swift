//
//  MemoryRandomWalkCoreTests.swift
//  HoloTests
//
//  随机漫步核心逻辑单测（暖光规格 §5）：
//  - 抽样：等权/首抽≥30天优先/已看排除/耗尽返回 nil/重开首站避开刚看过
//  - 回看一句：想法引用/傍晚模板/单笔记录不出句/摘句提取
//  - 历史日期索引：与 Provider 同口径的可见性/去重/跨日副本守卫
//  - 结果区排序：可靠时刻升序、无可靠置后
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class MemoryRandomWalkCoreTests: XCTestCase {

    private var context: NSManagedObjectContext {
        CoreDataTestSupport.sharedTestContainer.viewContext
    }

    override func setUp() async throws {
        try await MainActor.run {
            try CoreDataTestSupport.clearEntities(context, ["Transaction", "Habit", "HabitRecord", "TodoTask", "Thought"])
        }
    }

    private func makeDay(_ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = month
        c.day = day
        c.hour = 12
        return Calendar.current.date(from: c) ?? Date()
    }

    // MARK: - 抽样器
    // 生产传入的候选/已看集合都是 startOfDay（索引 days 与抵达提交口径），测试同口径。

    private func day(_ month: Int, _ day: Int) -> Date {
        Calendar.current.startOfDay(for: makeDay(month, day))
    }

    func test_sampler_首抽优先远期候选() {
        // 候选：1 天前 + 40 天前；首抽必须从 ≥30 天的子集里抽。
        let today = makeDay(11, 14)
        let near = day(11, 13)
        let far = day(10, 5)
        let sampler = MemoryRandomWalkSampler(next: { 0.0 })
        let drawn = sampler.draw(candidates: [near, far], excluding: [], today: today,
                                 calendar: Calendar.current, isFirstOfRound: true, lastSeen: nil)
        XCTAssertEqual(drawn, far)
    }

    func test_sampler_无远期候选时全池等权() {
        let today = makeDay(11, 14)
        let a = day(11, 13)
        let b = day(11, 12)
        // 注入 0.99 → 取池尾（b 按候选序在后）
        let sampler = MemoryRandomWalkSampler(next: { 0.99 })
        let drawn = sampler.draw(candidates: [a, b], excluding: [], today: today,
                                 calendar: Calendar.current, isFirstOfRound: true, lastSeen: nil)
        XCTAssertEqual(drawn, b)
    }

    func test_sampler_已看排除与耗尽() {
        let today = makeDay(11, 14)
        let a = day(11, 13)
        let sampler = MemoryRandomWalkSampler(next: { 0.0 })
        let drawn = sampler.draw(candidates: [a], excluding: [a],
                                 today: today, calendar: Calendar.current,
                                 isFirstOfRound: false, lastSeen: nil)
        XCTAssertNil(drawn, "唯一候选已看过应返回 nil")
    }

    func test_sampler_重开首站避开刚看过() {
        let today = makeDay(11, 14)
        let a = day(10, 5)
        let b = day(9, 20)
        let sampler = MemoryRandomWalkSampler(next: { 0.0 })
        let drawn = sampler.draw(candidates: [a, b], excluding: [],
                                 today: today, calendar: Calendar.current,
                                 isFirstOfRound: true, lastSeen: a)
        XCTAssertEqual(drawn, b, "首站应避开刚看过的 a")
    }

    // MARK: - 回看一句

    private func makeEvent(module: CalendarModule, month: Int, day: Int, hour: Int,
                           title: String, objectID: NSManagedObjectID) -> CalendarEvent {
        var c = DateComponents()
        c.year = 2026; c.month = month; c.day = day; c.hour = hour
        return CalendarEvent(module: module, date: Calendar.current.date(from: c) ?? Date(),
                             title: title, originID: objectID)
    }

    private lazy var sharedObjectID: NSManagedObjectID = {
        let thought = context.insertTestObject(Thought.self)
        thought.id = UUID()
        thought.content = "占位"
        try? context.save()
        return thought.objectID
    }()

    func test_echo_优先引用想法原文() {
        let events = [
            makeEvent(module: .finance, month: 5, day: 21, hour: 17, title: "营养土", objectID: sharedObjectID),
            makeEvent(module: .thought, month: 5, day: 21, hour: 20,
                      title: "薄荷换盆后，闻起来满手都是薄荷味。",
                      objectID: sharedObjectID),
        ]
        let echo = MemoryWalkEchoBuilder.echo(for: events, visiblePreviews: ["营养土"])
        XCTAssertEqual(echo?.text, "你那天写道：“薄荷换盆后，闻起来满手都是薄荷味。”")
        XCTAssertEqual(echo?.sourceEventID, events[1].id)
        XCTAssertEqual(echo?.ruleVersion, "walk-echo-v1")
    }

    func test_echo_傍晚模板需要四条可靠时刻() {
        var events: [CalendarEvent] = [
            makeEvent(module: .thought, month: 5, day: 21, hour: 20,
                      title: "薄荷换盆后，闻起来满手都是薄荷味。", objectID: sharedObjectID),
        ]
        // 摘句与列表重复 → 引用句省略；此时走模板：补 3 条 19 点记录共 4 条可靠，
        // 18 点后占比 100% ≥ 0.65。
        for hour in [19, 19, 19] {
            events.append(makeEvent(module: .habit, month: 5, day: 21, hour: hour,
                                    title: "打卡", objectID: sharedObjectID))
        }
        let echo = MemoryWalkEchoBuilder.echo(for: events, visiblePreviews: events.map(\.title))
        XCTAssertEqual(echo?.text, "这一天的记录大多留在傍晚以后")
        XCTAssertNil(echo?.sourceEventID, "多条依据不开直达")
    }

    func test_echo_单笔记账不出句() {
        let events = [
            makeEvent(module: .finance, month: 5, day: 21, hour: 12, title: "营养土 ¥16", objectID: sharedObjectID),
        ]
        XCTAssertNil(MemoryWalkEchoBuilder.echo(for: events, visiblePreviews: []))
    }

    func test_excerpt_取想法第一句并截长句() {
        let short = makeEvent(module: .thought, month: 5, day: 21, hour: 20,
                              title: "薄荷换盆后，闻起来满手都是薄荷味。还浇了水。",
                              objectID: sharedObjectID)
        XCTAssertEqual(MemoryWalkEchoBuilder.excerpt(for: [short])?.text,
                       "薄荷换盆后，闻起来满手都是薄荷味。")
        let long = makeEvent(module: .thought, month: 5, day: 21, hour: 21,
                             title: String(repeating: "今天给自己做了一顿很认真的晚饭", count: 3) + "。",
                             objectID: sharedObjectID)
        XCTAssertEqual(MemoryWalkEchoBuilder.excerpt(for: [long])?.text.hasSuffix("…"), true)
        XCTAssertEqual(MemoryWalkEchoBuilder.excerpt(for: [long])?.text.count, 41)
    }

    // MARK: - 历史日期索引

    /// 索引类用例的隔离上下文：播种+构建全在私有队列 performAndWait 内完成，
    /// 规避 hosted XCTest + iOS 26.3 模拟器上 MainActor/CoreData 组合对象释放重复释放
    /// （CoreDataTestSupport 注释记载的系统层坑；生产路径本就走后台上下文）。
    private func makeIsolatedContext() throws -> NSManagedObjectContext {
        let isolated = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        isolated.persistentStoreCoordinator = CoreDataTestSupport.sharedTestContainer.persistentStoreCoordinator
        return isolated
    }

    // async 修法（在案坑·crash-sweep 第七类）：同步 @MainActor 测试里实例化
    // ThoughtRepository 等隔离类会在测试线程析构触发 MainActor backdeploy malloc 崩。
    func test_index_四模块可见性与同ID去重同Provider口径() async throws {
        let isolated = try makeIsolatedContext()
        let index: MemoryRandomWalkDayIndex = try isolated.performAndWait {
            // 记账：发生 ✓ / 软删 ✗ / 未来 ✗
            seedTransaction(in: isolated, id: UUID(), date: makeDay(5, 21), deleted: false)
            seedTransaction(in: isolated, id: UUID(), date: makeDay(5, 22), deleted: true)
            let future = isolated.insertTestObject(Transaction.self)
            future.id = UUID()
            future.date = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
            // 习惯：存活打卡 ✓ / 未完成打卡 ✗ / 归档父习惯的记录 ✗
            let habit = Habit.create(in: isolated, name: "薄荷养护", icon: "leaf", color: "#22C55E",
                                     type: .checkIn, targetValue: 0, unit: nil, isBadHabit: false)
            seedHabitRecord(in: isolated, id: UUID(), habitId: habit.id, date: makeDay(5, 21), completed: true)
            seedHabitRecord(in: isolated, id: UUID(), habitId: habit.id, date: makeDay(5, 23), completed: false)
            let archivedHabit = Habit.create(in: isolated, name: "旧习惯", icon: "leaf", color: "#22C55E",
                                             type: .checkIn, targetValue: 0, unit: nil, isBadHabit: false)
            archivedHabit.isArchived = true
            seedHabitRecord(in: isolated, id: UUID(), habitId: archivedHabit.id, date: makeDay(5, 21), completed: true)
            // 待办：已完成 ✓ / 归档 ✗ / 软删 ✗
            seedTodo(in: isolated, id: UUID(), date: makeDay(5, 21), archived: false, deleted: false)
            seedTodo(in: isolated, id: UUID(), date: makeDay(5, 21), archived: true, deleted: false)
            seedTodo(in: isolated, id: UUID(), date: makeDay(5, 21), archived: false, deleted: true)
            // 想法：正常 ✓ / 归档 ✗ / 软删 ✗
            seedThought(in: isolated, id: UUID(), date: makeDay(5, 21), archived: false, deleted: false)
            seedThought(in: isolated, id: UUID(), date: makeDay(5, 21), archived: true, deleted: false)
            seedThought(in: isolated, id: UUID(), date: makeDay(5, 21), archived: false, deleted: true)
            try? isolated.save()
            return MemoryRandomWalkDayIndexBuilder.build(in: isolated,
                                                         calendar: .current,
                                                         now: Date())
        }
        XCTAssertEqual(index.days.count, 1, "只有 5/21 一天应计入：\(index.days)")
        let day = try XCTUnwrap(index.days.first)
        let keys = index.keysByDay[day] ?? []
        XCTAssertEqual(keys.count, 4, "记账/习惯/待办/想法各 1 条")
        XCTAssertTrue(keys.contains { $0.module == .finance })
        XCTAssertTrue(keys.contains { $0.module == .habit })
        XCTAssertTrue(keys.contains { $0.module == .todo })
        XCTAssertTrue(keys.contains { $0.module == .thought })
    }

    func test_index_同ID跨日副本只计一天且守卫自洽() async throws {
        let isolated = try makeIsolatedContext()
        let shared = UUID()
        let dayA = makeDay(5, 21)
        let dayB = makeDay(5, 22)
        let index: MemoryRandomWalkDayIndex = isolated.performAndWait {
            // 同 ID 两份副本落在不同日。生产（SQLite）按 Z_PK 物理行号取最小者；
            // in-memory 库的行号不可稳定解析，哪份副本获胜是取数顺序决定的——
            // 这里只断言与漫步相关的恒定不变量：只计一天，且守卫与所选代表自洽。
            seedTransaction(in: isolated, id: shared, date: dayA, deleted: false)
            seedTransaction(in: isolated, id: shared, date: dayB, deleted: false)
            try? isolated.save()
            return MemoryRandomWalkDayIndexBuilder.build(in: isolated, calendar: .current, now: Date())
        }
        XCTAssertEqual(index.days.count, 1, "同 ID 跨日副本只应计入一天")
        let day = try XCTUnwrap(index.days.first)
        XCTAssertTrue(calendarDay(day) == calendarDay(dayA) || calendarDay(day) == calendarDay(dayB))
        let key = CalendarEventKey(module: .finance, id: shared)
        // 跨日守卫：与索引所选日一致为真，另一日必为假（漫步按日详情据此滤掉跨日副本）。
        XCTAssertTrue(index.isConsistent(key, with: day))
        let other = calendarDay(day) == calendarDay(dayA) ? dayB : dayA
        XCTAssertFalse(index.isConsistent(key, with: other))
    }

    // MARK: - 结果区排序

    func test_orderedPreviews_可靠时刻升序无可靠置后() {
        let timedLate = makeEvent(module: .finance, month: 5, day: 21, hour: 20, title: "晚", objectID: sharedObjectID)
        var zeroComps = DateComponents()
        zeroComps.year = 2026; zeroComps.month = 5; zeroComps.day = 21
        let untimed = CalendarEvent(module: .todo,
                                    date: Calendar.current.date(from: zeroComps) ?? Date(),
                                    title: "无时刻", originID: sharedObjectID)
        let timedEarly = makeEvent(module: .habit, month: 5, day: 21, hour: 9, title: "早", objectID: sharedObjectID)
        let ordered = MemoryRandomWalkSession.orderedPreviews(for: [timedLate, untimed, timedEarly])
        XCTAssertEqual(ordered.map(\.title), ["早", "晚", "无时刻"])
    }

    // MARK: - Seeding

    private func calendarDay(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    private func seedTransaction(in context: NSManagedObjectContext, id: UUID, date: Date, deleted: Bool) {
        let txn = context.insertTestObject(Transaction.self)
        txn.id = id
        txn.date = date
        if deleted { txn.deletedAt = Date() }
    }

    private func seedHabitRecord(in context: NSManagedObjectContext, id: UUID, habitId: UUID, date: Date, completed: Bool) {
        let record = context.insertTestObject(HabitRecord.self)
        record.id = id
        record.habitId = habitId
        record.date = date
        record.isCompleted = completed
    }

    private func seedTodo(in context: NSManagedObjectContext, id: UUID, date: Date, archived: Bool, deleted: Bool) {
        let task = context.insertTestObject(TodoTask.self)
        task.id = id
        task.title = "任务"
        task.completedAt = date
        task.archived = archived
        if deleted { task.deletedAt = Date() }
    }

    private func seedThought(in context: NSManagedObjectContext, id: UUID, date: Date, archived: Bool, deleted: Bool) {
        let thought = context.insertTestObject(Thought.self)
        thought.id = id
        thought.content = "占位内容足够长以成为可读正文"
        thought.createdAt = date
        thought.isArchived = archived
        if deleted { thought.deletedAt = Date() }
    }
}

private func makeDay(_ month: Int, _ day: Int, hour: Int, minute: Int, second: Int) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = second
    return Calendar.current.date(from: c) ?? Date()
}
