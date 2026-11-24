//
//  HabitTodayLightsTests.swift
//  HoloTests
//
//  2026-11-23 审美七项 P1：页头「今日的灯」口径回归——
//  坏习惯不进灯；数值型「今日有记录」计入且为亮；顺序对齐今天页分节显示顺序
//  （打卡主角 → 数值 → 每周每月）；零好习惯为空数组。
//
//  夹具注意：必须「先播种、后 setup()」。仓库在 setup() 时缓存活跃 / 暂停习惯，
//  先 setup 后播种会拿到空名单（首轮全量测试 4 条全红即此因）。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HabitTodayLightsTests: XCTestCase {

    // MARK: 夹具（共享内存容器，见 CoreDataTestSupport 头注释）

    /// 清库 → 播种 → 仓库 setup() → 建视图模型并刷新
    private func makeModel(seed: (NSManagedObjectContext) throws -> Void) throws -> HabitModuleViewModel {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Habit", "HabitRecord"])
        try seed(context)
        try context.save()
        let repository = HabitRepository(context: context)
        repository.setup()
        let model = HabitModuleViewModel(repository: repository)
        // iOS 26.3 hosted XCTest 坑（在档）：局部 ObservableObject 测试结束销毁触发
        // malloc 非法释放——VM 与栈对象一并 retain 到进程结束
        CoreDataTestSupport.retain(repository, model)
        model.refresh()
        return model
    }

    @discardableResult
    private func seedHabit(_ context: NSManagedObjectContext, name: String,
                           type: HabitType, frequency: HabitFrequency = .daily,
                           aggregation: HabitAggregationType = .sum,
                           isBadHabit: Bool = false, sortOrder: Int16) throws -> Habit {
        let habit = context.insertTestObject(Habit.self)
        habit.id = UUID()
        habit.name = name
        habit.icon = "drop.fill"
        habit.color = "#3B76C9"
        habit.type = type.rawValue
        habit.frequency = frequency.rawValue
        habit.aggregationType = aggregation.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = sortOrder
        habit.createdAt = Date()
        habit.updatedAt = Date()
        return habit
    }

    private func seedRecord(_ context: NSManagedObjectContext, habitId: UUID,
                            isCompleted: Bool = false, value: Double? = nil) throws {
        let record = context.insertTestObject(HabitRecord.self)
        record.id = UUID()
        record.habitId = habitId
        record.date = Date()
        record.isCompleted = isCompleted
        record.valueDouble = value
        record.isRetroactive = false
    }

    // MARK: 用例

    func test_坏习惯不计入今日的灯() async throws {
        var goodId = UUID()
        let model = try makeModel { context in
            let good = try seedHabit(context, name: "好习惯", type: .checkIn, sortOrder: 0)
            _ = try seedHabit(context, name: "坏习惯", type: .checkIn, isBadHabit: true, sortOrder: 1)
            try seedRecord(context, habitId: good.id, isCompleted: true)
            goodId = good.id
        }

        XCTAssertEqual(model.todayRows.count, 2, "前提：好习惯与坏习惯都在今天页")
        XCTAssertEqual(model.todayLights.count, 1, "坏习惯不进「今日的灯」")
        XCTAssertEqual(model.todayLights.first?.id, goodId)
        XCTAssertEqual(model.todayLights.first?.isLit, true, "今天已记录的好习惯 = 亮")
        XCTAssertEqual(model.recordedTodayCount, 1, "原 recordedTodayCount 口径不变")
    }

    func test_数值型今日有记录计入且为亮() async throws {
        var recordedId = UUID()
        var pendingId = UUID()
        let model = try makeModel { context in
            let recorded = try seedHabit(context, name: "已记数值", type: .numeric, sortOrder: 0)
            let pending = try seedHabit(context, name: "未记数值", type: .numeric, sortOrder: 1)
            try seedRecord(context, habitId: recorded.id, value: 2)
            recordedId = recorded.id
            pendingId = pending.id
        }

        XCTAssertEqual(model.todayLights.count, 2, "数值型按「今日有记录」计入")
        XCTAssertEqual(model.todayLights.first { $0.id == recordedId }?.isLit, true,
                       "数值型今天有记录 = 亮")
        XCTAssertEqual(model.todayLights.first { $0.id == pendingId }?.isLit, false,
                       "数值型今天没记录 = 不亮")
    }

    func test_顺序对齐分节显示顺序_打卡主角在前数值次之周月最后() async throws {
        var ids: [UUID] = []
        let model = try makeModel { context in
            // 库内排序故意穿插：数值(sort 0) → 打卡(sort 1) → 周打卡(sort 2) → 计数(sort 3)
            let numeric = try seedHabit(context, name: "数值", type: .numeric, sortOrder: 0)
            let checkIn = try seedHabit(context, name: "打卡", type: .checkIn, sortOrder: 1)
            let weekly = try seedHabit(context, name: "周打卡", type: .checkIn,
                                       frequency: .weekly, sortOrder: 2)
            let counter = try seedHabit(context, name: "计数", type: .numeric, sortOrder: 3)
            ids = [numeric.id, checkIn.id, weekly.id, counter.id]
        }

        XCTAssertEqual(model.todayLights.map(\.id), [ids[1], ids[0], ids[3], ids[2]],
                       "灯序 = 今天页分节显示顺序（打卡主角 → 数值 → 每周每月），节内保持库内排序")
    }

    func test_零个好习惯时为空数组() async throws {
        let model = try makeModel { context in
            _ = try seedHabit(context, name: "坏习惯", type: .checkIn, isBadHabit: true, sortOrder: 0)
        }

        XCTAssertTrue(model.todayRows.contains { $0.isBadHabit }, "前提：坏习惯行存在")
        XCTAssertTrue(model.todayLights.isEmpty, "只有坏习惯时整行不显示")
    }
}
