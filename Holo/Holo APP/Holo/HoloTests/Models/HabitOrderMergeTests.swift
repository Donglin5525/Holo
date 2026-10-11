//
//  HabitOrderMergeTests.swift
//  HoloTests
//
//  2026-10-07 今天列表拖拽排序批次：
//  穿插合并纯函数（保槽位语义）+ persistTodayOrder 落库全链
//  （sortOrder 重编、未参与习惯原位不动）。
//

import XCTest
import CoreData
@testable import Holo

final class HabitOrderMergeTests: XCTestCase {

    // MARK: 纯函数

    func test_全量参与_新顺序整体生效() {
        let a = UUID(), b = UUID(), c = UUID()
        let merged = HabitOrderMerge.interleaveActive(allIds: [a, b, c], newActiveOrder: [c, a, b])
        XCTAssertEqual(merged, [c, a, b])
    }

    func test_暂停归档槽位保持_只换进行中相对顺序() {
        let a = UUID(), paused = UUID(), b = UUID(), archived = UUID(), c = UUID()
        let merged = HabitOrderMerge.interleaveActive(
            allIds: [a, paused, b, archived, c],
            newActiveOrder: [c, a, b]
        )
        // 参与槽位（a/b/c 位置）依次填新序；paused/archived 原位不动
        XCTAssertEqual(merged, [c, paused, a, archived, b])
    }

    func test_子集重排_缺席习惯原位不动且不重复不丢失() {
        // 「未记录」筛选下拖拽：视图只看到 a1/a3（a2 被隐藏）
        let a1 = UUID(), a2 = UUID(), a3 = UUID()
        let merged = HabitOrderMerge.interleaveActive(
            allIds: [a1, a2, a3],
            newActiveOrder: [a3, a1]
        )
        XCTAssertEqual(merged, [a3, a2, a1])
    }

    // MARK: 仓库落库全链

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?

    private func makeStack() throws -> HabitRepository {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitOrderMergeTest", managedObjectModel: model)
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
    private func makeHabit(in context: NSManagedObjectContext, name: String,
                           sortOrder: Int16, paused: Bool = false) throws -> Habit {
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
        habit.isPaused = paused
        habit.sortOrder = sortOrder
        habit.createdAt = Date()
        habit.updatedAt = Date()
        return habit
    }

    func test_persistTodayOrder_落库重编sortOrder_未参与习惯原位不动() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let h1 = try makeHabit(in: context, name: "一", sortOrder: 0)
        let h2 = try makeHabit(in: context, name: "二", sortOrder: 1)
        let paused = try makeHabit(in: context, name: "暂停", sortOrder: 2, paused: true)
        let h3 = try makeHabit(in: context, name: "三", sortOrder: 3)
        try context.save()
        repo.setup()

        // 用户把「三」拖到最前（今天页感知顺序：三、一、二；暂停习惯不在感知列表里）
        try repo.persistTodayOrder([h3.id, h1.id, h2.id])

        // 穿插合并：active 槽位（0/1/3）依次填新序 → [三, 一, 暂停, 二]；
        // 暂停习惯原槽位（2）保持。今天页 active 过滤后 = 三、一、二（用户感知顺序）
        let after = repo.fetchAllHabitsForReview()
        XCTAssertEqual(after.map(\.name), ["三", "一", "暂停", "二"])
        XCTAssertEqual(after.map(\.sortOrder), [0, 1, 2, 3])
        _ = paused
    }

    func test_persistTodayOrder_顺序未变时同样幂等落库() throws {
        let repo = try makeStack()
        let context = try XCTUnwrap(ctx)
        let h1 = try makeHabit(in: context, name: "一", sortOrder: 0)
        let h2 = try makeHabit(in: context, name: "二", sortOrder: 1)
        try context.save()
        repo.setup()

        try repo.persistTodayOrder([h1.id, h2.id])
        try repo.persistTodayOrder([h1.id, h2.id])

        XCTAssertEqual(repo.fetchAllHabitsForReview().map(\.name), ["一", "二"])
        XCTAssertEqual(repo.fetchAllHabitsForReview().map(\.sortOrder), [0, 1])
    }
}

// MARK: - 拖拽会话自愈（2026-10-11「习惯记录点击不动」根治）

/// isInteracting 的清除不能押「drag.onEnded 必然回调」——系统打断（来电/通知
/// 横幅/控制中心）不保证回调，会话状态会永久卡死，全页按钮 guard 静默吞点击。
/// 陈旧窗口（8s）后自愈为非交互态。
@MainActor
final class HabitReorderSessionSelfHealTests: XCTestCase {

    /// 模型钉住不释放：iOS 26.3 模拟器上 @MainActor 类在用例内局部释放会踩
    /// Swift 运行时 deinit-on-executor 的 malloc double-free（.ips 栈：
    /// swift_task_deinitOnExecutorMainActorBackDeploy），与产品逻辑无关
    nonisolated(unsafe) private static var pinnedModels: [HabitListReorderModel] = []

    private func makeActiveSession() -> (model: HabitListReorderModel, id: UUID) {
        let model = HabitListReorderModel()
        Self.pinnedModels.append(model)
        let a = UUID(), b = UUID()
        _ = model.effectiveIds(.today, baseline: [a, b]) // 喂 baseline（beginDrag 底序）
        model.beginDrag(id: a, section: .today, spacing: 8)
        return (model, a)
    }

    func test_激活即交互中() {
        let (model, _) = makeActiveSession()
        XCTAssertTrue(model.isInteracting)
    }

    func test_手势回调彻底丢失_陈旧后自愈放行交互() {
        let (model, _) = makeActiveSession()
        // 模拟 onEnded 永不到来：时间流逝超过陈旧窗口
        model.test_backdateGestureActivity(by: 9)
        XCTAssertFalse(model.isInteracting, "死会话应自愈为非交互态，否则全页点击被永久吞掉")
    }

    func test_窗口内仍算交互_拖动续命() {
        let (model, _) = makeActiveSession()
        model.test_backdateGestureActivity(by: 7)
        XCTAssertTrue(model.isInteracting, "8s 窗口内仍是活会话")
        model.test_backdateGestureActivity(by: 5) // 累计 12s
        model.dragMoved(translationY: 10, locationY: 300) // 手指动了 = 活着
        XCTAssertTrue(model.isInteracting)
    }

    func test_取消会话后陈旧自愈兜底() {
        let (model, _) = makeActiveSession()
        model.cancelDrag()
        // cancelDrag 后 isLifting 有 0.2s 防误触锁窗；陈旧窗口覆盖它
        model.test_backdateGestureActivity(by: 9)
        XCTAssertFalse(model.isInteracting)
    }

    func test_死会话后拖拽可重启_陈旧清场不吞新会话() {
        let (model, a) = makeActiveSession()
        model.test_backdateGestureActivity(by: 9)
        XCTAssertFalse(model.isInteracting, "死会话自愈放行点击")
        // 死会话上再次长按：就地清场并开新会话（不是被 guard 静默拒绝）
        let b = UUID()
        _ = model.effectiveIds(.today, baseline: [b, a])
        model.beginDrag(id: b, section: .today, spacing: 8)
        XCTAssertTrue(model.isInteracting, "新会话应正常进入交互态")
        XCTAssertEqual(model.draggingId, b)
    }

    func test_活会话内拒绝重入() {
        let (model, a) = makeActiveSession()
        let b = UUID()
        _ = model.effectiveIds(.today, baseline: [b, a])
        model.beginDrag(id: b, section: .today, spacing: 8)
        XCTAssertEqual(model.draggingId, a, "活会话内第二次激活应被拒绝")
    }

    func test_正常落座后交互结束() {
        let (model, _) = makeActiveSession()
        model.endDrag()
        XCTAssertTrue(model.isInteracting, "0.2s 防误触锁窗内仍挡点击")
        model.test_backdateGestureActivity(by: 9)
        XCTAssertFalse(model.isInteracting)
    }
}

