//
//  HabitActionCoordinatorTests.swift
//  HoloTests
//
//  2026-10 习惯交互重构动作层验证（方案 §15 G1）：
//  保存失败 scoped 恢复、重复提交、精确撤销不误删、指纹校验、
//  值校验（计数>0 / 测量含0）、三态字段清除、关系保存失败报错。
//

import XCTest
import CoreData
@testable import Holo

/// save 必败的 context（干净失败注入：不依赖模型验证）
final class FailingSaveContext: NSManagedObjectContext {
    override func save() throws {
        throw NSError(domain: "HoloTest.saveFailed", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "注入的保存失败"])
    }
}

@MainActor
final class HabitActionCoordinatorTests: XCTestCase {

    private var container: NSPersistentContainer?
    private var ctx: NSManagedObjectContext?
    private var repo: HabitRepository?
    private var coordinator: HabitActionCoordinator?

    private func makeStack() throws -> (HabitActionCoordinator, HabitRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let c = NSPersistentContainer(name: "HabitActionTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        c.persistentStoreDescriptions = [description]
        var storeError: Error?
        c.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let context = c.viewContext
        let repository = HabitRepository(context: context)
        let actionCoordinator = HabitActionCoordinator(repository: repository)
        CoreDataTestSupport.retain(c, context, repository, actionCoordinator)
        container = c
        ctx = context
        repo = repository
        coordinator = actionCoordinator
        return (actionCoordinator, repository, context)
    }

    private func makeHabit(in context: NSManagedObjectContext,
                           type: HabitType = .checkIn,
                           aggregation: HabitAggregationType = .sum,
                           targetValue: Double? = nil,
                           unit: String? = nil) throws -> Habit {
        let habit = NSEntityDescription.insertNewObject(forEntityName: "Habit", into: context) as! Habit
        habit.id = UUID()
        habit.name = "好好喝水"
        habit.icon = "drop.fill"
        habit.color = "#3B76C9"
        habit.type = type.rawValue
        habit.frequency = HabitFrequency.daily.rawValue
        habit.aggregationType = aggregation.rawValue
        habit.isBadHabit = false
        habit.isArchived = false
        habit.sortOrder = 0
        habit.createdAt = Date()
        habit.updatedAt = Date()
        habit.targetValue = targetValue.map { NSNumber(value: $0) }
        habit.unit = unit
        return habit
    }

    private func todayRecordCount(habitId: UUID, in context: NSManagedObjectContext) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND date >= %@ AND date < %@ AND deletedAt == nil",
            habitId as CVarArg, today as NSDate, tomorrow as NSDate
        )
        return (try? context.fetch(request))?.count ?? 0
    }

    /// 把仓库切到 save 必败的 context（scoped 恢复路径的真实触发）
    private func injectSaveFailure(repository: HabitRepository, coordinator: NSPersistentStoreCoordinator? = nil) -> FailingSaveContext {
        let failing = FailingSaveContext(concurrencyType: .mainQueueConcurrencyType)
        if let coordinator {
            failing.persistentStoreCoordinator = coordinator
        }
        repository.context = failing
        return failing
    }

    // MARK: - 打卡回执

    func test_打卡成功与取消都是真实保存() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context)
        try context.save()

        let first = await actionCoordinator.perform(.toggleCheckIn, habitId: habit.id)
        guard case .confirmed(let firstReceipt) = first else {
            return XCTFail("首次打卡应成功，实际 \(first.map(String.init(describing:)) ?? "nil")")
        }
        XCTAssertEqual(firstReceipt.newCheckInState, true)
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 1)

        // 再点一次 = 取消（toggle 语义），不算失败
        let second = await actionCoordinator.perform(.toggleCheckIn, habitId: habit.id)
        guard case .confirmed(let secondReceipt) = second else {
            return XCTFail("取消打卡也是成功保存")
        }
        XCTAssertEqual(secondReceipt.newCheckInState, false, "false 是用户成功取消，不是保存失败（R04）")
    }

    func test_打卡撤销恢复原状态() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context)
        try context.save()

        guard case .confirmed(let receipt) = await actionCoordinator.perform(.toggleCheckIn, habitId: habit.id) else {
            return XCTFail("打卡应成功")
        }

        let undoResult = actionCoordinator.undo(receipt)
        guard case .confirmed = undoResult else {
            return XCTFail("撤销应成功，实际 \(undoResult)")
        }
        let repo = try XCTUnwrap(repo)
        let habitReloaded = try XCTUnwrap(repo.findHabit(by: habit.id))
        XCTAssertFalse(repo.isTodayCompleted(for: habitReloaded), "撤销后恢复未记录状态")
        // 记录行保留（取消态，同一条记录不重复插入）
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 1)
    }

    // MARK: - 数值与撤销

    func test_测量保存0是有效记录() async throws {
        let (actionCoordinator, repo, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .latest, unit: "kg")
        try context.save()

        let result = await actionCoordinator.perform(.addNumeric(value: 0), habitId: habit.id)
        guard case .confirmed = result else {
            return XCTFail("测量 0 应保存成功（真实 0 有效）")
        }
        let habitReloaded = try XCTUnwrap(repo.findHabit(by: habit.id))
        XCTAssertEqual(repo.getTodayValue(for: habitReloaded), 0, "0 不是 nil")
    }

    func test_计数负值与0被拒绝() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, targetValue: 8)
        try context.save()

        let negative = await actionCoordinator.perform(.addNumeric(value: -1), habitId: habit.id)
        guard case .invalidated(.invalidValue) = negative else {
            return XCTFail("计数 -1 应拒绝")
        }
        let zero = await actionCoordinator.perform(.addNumeric(value: 0), habitId: habit.id)
        guard case .invalidated(.invalidValue) = zero else {
            return XCTFail("计数 0 无意义（>0 才是新增）应拒绝")
        }
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 0, "非法输入不写入")
    }

    func test_精确撤销不误删后续记录_R08() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum)
        try context.save()

        // A：一条 3 杯；随后 B：一条 1 杯
        guard case .confirmed(let receiptA) = await actionCoordinator.perform(.addNumeric(value: 3), habitId: habit.id) else {
            return XCTFail("A 应成功")
        }
        _ = await actionCoordinator.perform(.addNumeric(value: 1), habitId: habit.id)
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 2)

        // 撤销 A：只删 A 那条，B 保留
        let undoResult = actionCoordinator.undo(receiptA)
        guard case .confirmed = undoResult else {
            return XCTFail("撤销 A 应成功")
        }
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 1, "B 不被误删")
    }

    func test_记录被改后撤销拒绝() async throws {
        let (actionCoordinator, repo, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .latest)
        try context.save()

        guard case .confirmed(let receipt) = await actionCoordinator.perform(.addNumeric(value: 64.2), habitId: habit.id) else {
            return XCTFail("应成功")
        }

        // 用户（或同步）改了这条记录
        let recordId = try XCTUnwrap(receipt.recordId)
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordId as CVarArg)
        let record = try XCTUnwrap(try context.fetch(request).first)
        record.value = NSNumber(value: 70.0)
        try context.save()
        _ = repo

        let undoResult = actionCoordinator.undo(receipt)
        guard case .invalidated(.recordChanged) = undoResult else {
            return XCTFail("指纹不符应拒绝撤销，实际 \(undoResult)")
        }
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 1, "拒绝时不动数据")
    }

    // MARK: - 保存失败 scoped 恢复（R12/R13）

    func test_保存失败保留输入不产生假记录() async throws {
        let (actionCoordinator, repo, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .latest, unit: "kg")
        try context.save()

        injectSaveFailure(repository: repo, coordinator: context.persistentStoreCoordinator)
        let result = await actionCoordinator.perform(.addNumeric(value: 63.5), habitId: habit.id)
        guard case .failed = result else {
            return XCTFail("保存失败应返回 failed，实际 \(result.map(String.init(describing:)) ?? "nil")")
        }

        // 恢复仓库后重查：失败的操作不能留下假记录（R12）
        repo.context = context
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 0,
                       "失败的新增记录必须被 scoped 恢复（重 fetch 不能看到假记录）")
    }

    func test_保存失败不清除其他模块未保存修改_R13() async throws {
        let (actionCoordinator, repo, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .latest)
        try context.save()

        let failing = injectSaveFailure(repository: repo, coordinator: context.persistentStoreCoordinator)
        // 另一个模块（模拟）在同一 context 有一笔未保存的合法修改
        let foreign = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: failing) as! HabitRecord
        foreign.id = UUID()
        foreign.habitId = UUID()
        foreign.date = Date()
        foreign.isCompleted = true
        foreign.createdAt = Date()

        let result = await actionCoordinator.perform(.addNumeric(value: 1.5), habitId: habit.id)
        guard case .failed = result else {
            return XCTFail("应失败")
        }

        // 失败后：其他模块的未保存修改仍完好（绝不清 context）
        let stillThere = failing.registeredObjects.contains {
            ($0 as? HabitRecord)?.id == foreign.id && !$0.isDeleted
        }
        XCTAssertTrue(stillThere, "scoped 恢复不得清除其他待保存数据")
    }

    // MARK: - 三态编辑（R21/R47）

    func test_三态清除目标真实移除() async throws {
        let (repo, repoRef, context) = try makeStack()
        _ = repo
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, targetValue: 8, unit: "杯")
        try context.save()

        var payload = HabitEditPayload(name: "好好喝水", icon: "drop.fill", color: "#3B76C9",
                                       type: .numeric, aggregationType: .sum)
        payload.targetValue = .clear
        payload.unit = .clear
        try repoRef.applyHabitEdits(habitId: habit.id, payload: payload)

        let habitReloaded = try XCTUnwrap(repoRef.findHabit(by: habit.id))
        XCTAssertNil(habitReloaded.targetValue, "清除目标后 NSNumber 必须真移除")
        XCTAssertNil(habitReloaded.unit)
        XCTAssertEqual(habitReloaded.name, "好好喝水")
    }

    func test_三态设置与保留() async throws {
        let (repo, repoRef, context) = try makeStack()
        _ = repo
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum, targetValue: 8, unit: "杯")
        try context.save()

        var payload = HabitEditPayload(name: "好好喝水", icon: "drop.fill", color: "#3B76C9",
                                       type: .numeric, aggregationType: .sum)
        payload.targetValue = .set(10)
        // targetCount 与 unit 保持 .keep
        try repoRef.applyHabitEdits(habitId: habit.id, payload: payload)

        let habitReloaded = try XCTUnwrap(repoRef.findHabit(by: habit.id))
        XCTAssertEqual(habitReloaded.targetValueDouble, 10)
        XCTAssertEqual(habitReloaded.unit, "杯", ".keep 不修改")
    }

    func test_空名字拒绝保存() async throws {
        let (_, repoRef, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .checkIn)
        try context.save()

        let payload = HabitEditPayload(name: "   ", icon: "drop.fill", color: "#3B76C9", type: .checkIn)
        XCTAssertThrowsError(try repoRef.applyHabitEdits(habitId: habit.id, payload: payload))
    }

    // MARK: - 重复提交（R15）

    func test_顺序多次increment各自成功() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .numeric, aggregation: .sum)
        try context.save()

        for _ in 0..<3 {
            let result = await actionCoordinator.perform(.increment(amount: 1), habitId: habit.id)
            guard case .confirmed = result else { return XCTFail("每次 +1 都是独立意图") }
        }
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 3)
    }

    func test_保存中同习惯动作被忽略() async throws {
        let (actionCoordinator, _, context) = try makeStack()
        let habit = try makeHabit(in: context, type: .checkIn)
        try context.save()

        actionCoordinator.savingHabitIds.insert(habit.id)
        let result = await actionCoordinator.perform(.toggleCheckIn, habitId: habit.id)
        XCTAssertNil(result, "同习惯保存中，新动作被忽略不产生新意图")
        XCTAssertEqual(todayRecordCount(habitId: habit.id, in: context), 0)
    }
}
