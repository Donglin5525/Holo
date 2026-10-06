//
//  HabitRepositoryReadinessTests.swift
//  Holo
//
//  仓库层就绪门治理回归（2026-10-07）：共享 store 未装载完成期间，
//  setup()/loadActiveHabits()/findHabit() 必须推迟排队而非阻塞调用线程，
//  装载完成后补跑并广播。18 处「用到才初始化」调用点全部经 setup() 漏斗受护。
//
//  仪器说明：注入独立 context 的实例默认天然旁路就绪门（保既有 108 测不变），
//  延迟路径经 init 的 readinessGateOverride 注入开合。
//

import XCTest
import CoreData
@testable import Holo

final class HabitRepositoryReadinessTests: XCTestCase {

    private func makeCtx() throws -> (container: NSPersistentContainer, ctx: NSManagedObjectContext) {
        let container = NSPersistentContainer(name: "HabitReadinessTest", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        return (container, container.viewContext)
    }

    @discardableResult
    private func seedHabit(in ctx: NSManagedObjectContext) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: ctx) as! Habit
        habit.id = UUID()
        habit.name = "就绪门测试习惯"
        habit.icon = "drop.fill"
        habit.color = "#3B82F6"
        habit.type = HabitType.checkIn.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = HabitAggregationType.sum.rawValue
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
        try ctx.save()
        return habit
    }

    /// 门关着时 setup() 必须推迟：不同步置 isReady、不同步取数
    func test_setup_门关时推迟不置就绪() throws {
        let (container, ctx) = try makeCtx()
        _ = try seedHabit(in: ctx)
        let repo = HabitRepository(context: ctx, readinessGateOverride: { true })
        CoreDataTestSupport.retain(container, ctx, repo)

        repo.setup()

        XCTAssertFalse(repo.isReady, "门关着时 setup 不得同步置就绪")
        XCTAssertTrue(repo.activeHabits.isEmpty, "门关着时 setup 不得同步取数")
    }

    /// 门开后排队补跑：装载完成后 setup 补跑 + 广播 + 数据可见
    /// （override 闭包语义 = 是否推迟；deferNow=true 表示共享 store 尚未装载完成）
    func test_门开后延迟补跑加载并广播() throws {
        let (container, ctx) = try makeCtx()
        _ = try seedHabit(in: ctx)
        var deferNow = true
        let repo = HabitRepository(context: ctx, readinessGateOverride: { deferNow })
        CoreDataTestSupport.retain(container, ctx, repo)

        repo.setup()
        XCTAssertFalse(repo.isReady)

        var broadcasts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .habitDataDidChange, object: nil, queue: nil
        ) { _ in broadcasts += 1 }

        deferNow = false
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in repo.isReady }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed,
                       "门开后 deferred setup 应在共享 store 装载后补跑完成")

        XCTAssertEqual(repo.activeHabits.count, 1, "补跑后应取到已播种的习惯")
        XCTAssertGreaterThanOrEqual(broadcasts, 1, "补跑完成必须广播 habitDataDidChange 唤醒已上屏视图")
        NotificationCenter.default.removeObserver(observer)
    }

    /// 注入 context 的实例默认旁路就绪门（既有 108 测兼容性契约）
    func test_注入context默认旁路门() throws {
        let (container, ctx) = try makeCtx()
        let repo = HabitRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repo)

        repo.setup()

        XCTAssertTrue(repo.isReady, "注入独立 context 的实例不经过共享 store 就绪门，行为与历史一致")
    }

    /// loadActiveHabits 外部直呼同样过门：门关时排队不取数，门开后补跑可见
    func test_加载入口直呼过门() throws {
        let (container, ctx) = try makeCtx()
        _ = try seedHabit(in: ctx)
        var deferNow = true
        let repo = HabitRepository(context: ctx, readinessGateOverride: { deferNow })
        CoreDataTestSupport.retain(container, ctx, repo)

        repo.loadActiveHabits()
        XCTAssertTrue(repo.activeHabits.isEmpty, "门关时直呼加载不得同步取数")

        deferNow = false
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in repo.isReady }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed,
                       "排队补跑应把 setup 一并完成")
        XCTAssertEqual(repo.activeHabits.count, 1)
    }

    /// findHabit 同门：门关时返回 nil（弹层兜底+广播后自愈），不阻塞
    func test_findHabit门关返回nil() throws {
        let (container, ctx) = try makeCtx()
        let habit = try seedHabit(in: ctx)
        let repo = HabitRepository(context: ctx, readinessGateOverride: { true })
        CoreDataTestSupport.retain(container, ctx, repo)

        XCTAssertNil(repo.findHabit(by: habit.id), "门关时 findHabit 应返回 nil 而非阻塞取数")
        XCTAssertFalse(repo.isReady)
    }
}
