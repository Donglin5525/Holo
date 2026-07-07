//
//  CalendarEventProviderTests.swift
//  HoloTests
//
//  CalendarEventProvider 单测：
//  - aggregate 纯函数（合并/排序/失败态/empty）
//  - fetchEvents 集成（in-memory 4 repo，验证调度 + 想法映射）
//

import XCTest
import CoreData
@testable import Holo

final class CalendarEventProviderTests: XCTestCase {

    // MARK: - 测试 helper

    /// 共享一个 in-memory context 仅为取 NSManagedObjectID（aggregate 测试用）
    private lazy var idContext: NSManagedObjectContext = {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "ProviderIDTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container.viewContext
    }()

    private lazy var sharedObjectID: NSManagedObjectID = {
        let thought = Thought(context: idContext)
        thought.id = UUID()
        thought.content = "占位"
        thought.createdAt = Date()
        try? idContext.save()
        return thought.objectID
    }()

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    /// 造一个 CalendarEvent（用共享 objectID，originID 内容对 aggregate 测试无关）
    private func makeEvent(_ module: CalendarModule, day: Int, hour: Int = 0) -> CalendarEvent {
        CalendarEvent(
            module: module,
            date: makeDate(year: 2026, month: 7, day: day, hour: hour),
            title: "T\(day)",
            detail: nil,
            originID: sharedObjectID
        )
    }

    private func makeEvent(_ module: CalendarModule, day: Int, hour: Int, minute: Int) -> CalendarEvent {
        var c = DateComponents()
        c.year = 2026
        c.month = 7
        c.day = day
        c.hour = hour
        c.minute = minute
        return CalendarEvent(
            module: module,
            date: Calendar.current.date(from: c) ?? Date(),
            title: "T\(day)-\(hour)-\(minute)",
            detail: nil,
            originID: sharedObjectID
        )
    }

    // MARK: - aggregate 纯函数

    func test_aggregate全成功_合并并按date升序() {
        let partials: [CalendarEventProvider.Partial] = [
            .init(module: .finance,
                  events: [makeEvent(.finance, day: 2, hour: 10), makeEvent(.finance, day: 1, hour: 9)],
                  state: .loaded),
            .init(module: .habit,
                  events: [makeEvent(.habit, day: 1, hour: 8)],
                  state: .loaded)
        ]
        let result = CalendarEventProvider.aggregate(partials: partials)

        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0].date, makeDate(year: 2026, month: 7, day: 1, hour: 8))
        XCTAssertEqual(result.events[1].date, makeDate(year: 2026, month: 7, day: 1, hour: 9))
        XCTAssertEqual(result.events[2].date, makeDate(year: 2026, month: 7, day: 2, hour: 10))
        XCTAssertEqual(result.moduleStates[.finance], .loaded)
        XCTAssertEqual(result.moduleStates[.habit], .loaded)
        XCTAssertFalse(result.hasFailure)
    }

    func test_aggregate单模块失败_不阻塞其他() {
        let partials: [CalendarEventProvider.Partial] = [
            .init(module: .finance, events: [makeEvent(.finance, day: 1)], state: .loaded),
            .init(module: .todo, events: [], state: .failed(message: "待办仓储挂了"))
        ]
        let result = CalendarEventProvider.aggregate(partials: partials)

        XCTAssertEqual(result.events.count, 1, "失败模块不计入 events，但不影响其他")
        XCTAssertEqual(result.events.first?.module, .finance)
        XCTAssertEqual(result.moduleStates[.finance], .loaded)
        XCTAssertEqual(result.moduleStates[.todo], .failed(message: "待办仓储挂了"))
        XCTAssertTrue(result.hasFailure, "应标记存在失败")
        XCTAssertEqual(result.failedModules, [.todo])
    }

    func test_aggregate全失败_events空且全failed() {
        let partials: [CalendarEventProvider.Partial] = [
            .init(module: .finance, events: [], state: .failed(message: "e1")),
            .init(module: .habit, events: [], state: .failed(message: "e2"))
        ]
        let result = CalendarEventProvider.aggregate(partials: partials)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.moduleStates[.finance], .failed(message: "e1"))
        XCTAssertEqual(result.moduleStates[.habit], .failed(message: "e2"))
        XCTAssertTrue(result.hasFailure)
    }

    func test_aggregate空区间_各模块empty() {
        let partials: [CalendarEventProvider.Partial] = [
            .init(module: .finance, events: [], state: .empty),
            .init(module: .habit, events: [], state: .empty)
        ]
        let result = CalendarEventProvider.aggregate(partials: partials)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.moduleStates[.finance], .empty)
        XCTAssertEqual(result.moduleStates[.habit], .empty)
        XCTAssertFalse(result.hasFailure, "空数据不是失败")
    }

    // MARK: - 展示层模型

    func test_weeklyGridLayout同时间事件拆成并列lane避免重叠() {
        let events = [
            makeEvent(.finance, day: 1, hour: 15, minute: 26),
            makeEvent(.todo, day: 1, hour: 15, minute: 26),
            makeEvent(.thought, day: 1, hour: 15, minute: 31)
        ]

        let items = WeeklyGridEventLayout.layout(events: events, startHour: 6, endHour: 23, hourHeight: 42)

        XCTAssertEqual(items.visible.count, 3)
        XCTAssertEqual(Set(items.visible.map(\.laneCount)), [3], "同一时间簇应共享 laneCount")
        XCTAssertEqual(Set(items.visible.map(\.lane)), [0, 1, 2], "同一时间簇应拆成不同 lane")
    }

    func test_weeklyGridLayout凌晨事件进入earlyBucket而不是夹到6点() {
        let events = [
            makeEvent(.finance, day: 1, hour: 0, minute: 0),
            makeEvent(.habit, day: 1, hour: 7, minute: 30)
        ]

        let items = WeeklyGridEventLayout.layout(events: events, startHour: 6, endHour: 23, hourHeight: 42)

        XCTAssertEqual(items.early.count, 1)
        XCTAssertEqual(items.visible.count, 1)
        XCTAssertEqual(items.visible.first?.event.module, .habit)
    }

    func test_weeklyGridLayout同一小时多模块合并成模块摘要() {
        let events = [
            makeEvent(.habit, day: 1, hour: 10, minute: 2),
            makeEvent(.habit, day: 1, hour: 10, minute: 9),
            makeEvent(.finance, day: 1, hour: 10, minute: 16),
            makeEvent(.thought, day: 1, hour: 10, minute: 41)
        ]

        let items = WeeklyGridEventLayout.layout(events: events, startHour: 6, endHour: 23, hourHeight: 42)

        XCTAssertEqual(items.displayItems.count, 3)
        XCTAssertEqual(items.displayItems.map(\.module), [.finance, .habit, .thought])
        XCTAssertEqual(items.displayItems.first(where: { $0.module == .habit })?.displayTitle, "习惯 +2")
        XCTAssertEqual(items.displayItems.first(where: { $0.module == .habit })?.events.count, 2)
        XCTAssertTrue(items.displayItems.allSatisfy { $0.isSummary }, "多模块拥挤时应展示模块摘要，明细进弹窗")
        XCTAssertEqual(Set(items.displayItems.map(\.lane)), [0], "多模块摘要应纵向堆叠，避免左右挤压成省略号")
        XCTAssertEqual(Set(items.displayItems.map(\.laneCount)), [1], "多模块摘要应占满列宽")
        XCTAssertEqual(Set(items.displayItems.map(\.stackCount)), [3])
        XCTAssertEqual(items.displayItems.map(\.stackIndex), [0, 1, 2])
        XCTAssertEqual(items.displayItems.map(\.top), [168, 182, 196])
    }

    func test_weeklyGridLayout同一小时单模块保持自然胶囊() {
        let events = [
            makeEvent(.habit, day: 1, hour: 14, minute: 3),
            makeEvent(.habit, day: 1, hour: 14, minute: 18),
            makeEvent(.habit, day: 1, hour: 14, minute: 43)
        ]

        let items = WeeklyGridEventLayout.layout(events: events, startHour: 6, endHour: 23, hourHeight: 42)

        XCTAssertEqual(items.displayItems.count, 1)
        XCTAssertEqual(items.displayItems.first?.displayTitle, "T1-14-3 +3")
        XCTAssertEqual(items.displayItems.first?.events.count, 3)
        XCTAssertFalse(items.displayItems.first?.isSummary ?? true, "单模块拥挤时仍用胶囊表达，不退化成模块名")
    }

    func test_weeklyGridLayout零到六点折叠后七点开始展示() {
        let events = [
            makeEvent(.finance, day: 1, hour: 0, minute: 10),
            makeEvent(.habit, day: 1, hour: 6, minute: 30),
            makeEvent(.todo, day: 1, hour: 7, minute: 45),
            makeEvent(.thought, day: 1, hour: 8, minute: 5)
        ]

        let items = WeeklyGridEventLayout.layout(
            events: events,
            startHour: 7,
            endHour: 23,
            hourHeight: 42,
            collapsedHours: 0..<7
        )

        XCTAssertTrue(items.early.isEmpty)
        XCTAssertEqual(items.collapsed.count, 2)
        XCTAssertEqual(items.displayItems.map(\.module), [.todo, .thought])
        XCTAssertEqual(items.displayItems.first?.top, 0)
    }

    func test_calendarObservationSummary生成本地可信观察() {
        let events = [
            makeEvent(.finance, day: 1, hour: 14, minute: 0),
            makeEvent(.finance, day: 1, hour: 15, minute: 0),
            makeEvent(.thought, day: 2, hour: 22, minute: 0),
            makeEvent(.habit, day: 3, hour: 8, minute: 0)
        ]

        let summary = CalendarObservationSummary.make(events: events, scope: .week)

        XCTAssertEqual(summary.source, .local)
        XCTAssertFalse(summary.title.isEmpty)
        XCTAssertTrue(summary.evidence.contains("4 条记录"))
        XCTAssertTrue(summary.evidence.contains("3 个模块"))
    }

    // MARK: - fetchEvents 集成

    func test_fetchEvents_想法数据正确映射且其他模块empty() async throws {
        let (provider, _) = try makeProviderWithThought()

        let result = await provider.fetchEvents(in: DateInterval(
            start: makeDate(year: 2026, month: 7, day: 1),
            end: makeDate(year: 2026, month: 7, day: 2)
        ))

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.module, .thought)
        XCTAssertEqual(result.moduleStates[.thought], .loaded)
        XCTAssertEqual(result.moduleStates[.finance], .empty)
        XCTAssertEqual(result.moduleStates[.habit], .empty)
        XCTAssertEqual(result.moduleStates[.todo], .empty)
        XCTAssertFalse(result.hasFailure)
    }

    /// 造一个含 1 条想法的 in-memory provider
    private func makeProviderWithThought() throws -> (CalendarEventProvider, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "ProviderIntegration", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext

        let thought = Thought(context: ctx)
        thought.id = UUID()
        thought.content = "测试想法"
        thought.createdAt = makeDate(year: 2026, month: 7, day: 1, hour: 9)
        thought.updatedAt = thought.createdAt
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()

        let provider = CalendarEventProvider(
            financeRepo: FinanceRepository(context: ctx),
            habitRepo: HabitRepository(context: ctx),
            todoRepo: TodoRepository(context: ctx),
            thoughtRepo: ThoughtRepository(context: ctx)
        )
        return (provider, ctx)
    }
}
