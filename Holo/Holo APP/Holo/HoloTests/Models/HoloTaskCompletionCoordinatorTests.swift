//
//  HoloTaskCompletionCoordinatorTests.swift
//  HoloTests
//
//  完成协调层（G1 完成契约）逻辑单测：
//  撤回窗口内不落库、confirm 落库、重复任务生成下一实例、
//  撤回恢复触发子任务、连续完成显式确认、幂等、失败暴露 lastFailure。
//  计时用注入的假时钟手动触发，不等待真实 3 秒。
//  容器走 CoreDataTestSupport.sharedTestContainer（自建容器重复 load sharedModel
//  会触发实体映射全局歧义，R4-1 实锤；新增套件一律共享容器 + setUp 清实体）。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloTaskCompletionCoordinatorTests: XCTestCase {

    private var repo: TodoRepository!

    override func setUp() async throws {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["TodoTask", "CheckItem", "RepeatRule"])
        repo = TodoRepository(context: context)
        CoreDataTestSupport.retain(repo)
    }

    // MARK: - 夹具

    /// 假时钟：只记录调度，不发真实异步；测试手动 fireNow 触发 confirm
    private final class FakeConfirmTimer {
        private(set) var scheduleCount = 0
        private(set) var fire: (() -> Void)?

        func schedule(_ fireAt: Date, _ fire: @escaping () -> Void) -> () -> Void {
            scheduleCount += 1
            self.fire = fire
            return { [weak self] in self?.fire = nil }
        }

        func fireNow() {
            fire?()
        }
    }

    private func makeCoordinator(timer: FakeConfirmTimer) -> HoloTaskCompletionCoordinator {
        let coordinator = HoloTaskCompletionCoordinator()
        // hosted XCTest + iOS 26.3 模拟器对 MainActor ObservableObject 的释放存在
        // 系统层重复释放（CoreDataTestSupport 同款注记）：测试实例一律 retain 延寿。
        // 生产侧 .shared 单例永生，不受此环境问题影响。
        CoreDataTestSupport.retain(coordinator)
        coordinator.scheduleConfirm = { fireAt, fire in timer.schedule(fireAt, fire) }
        return coordinator
    }

    private func makeTaskWithItems(_ titles: [String]) throws -> (TodoTask, [CheckItem]) {
        let task = try repo.createTask(title: "整理房间")
        var items: [CheckItem] = []
        for (index, title) in titles.enumerated() {
            items.append(try repo.addCheckItem(title: title, to: task, order: Int16(index)))
        }
        return (task, items)
    }

    private func checkItems(of task: TodoTask) -> [CheckItem] {
        (task.checkItems?.allObjects as? [CheckItem] ?? []).sorted { $0.order < $1.order }
    }

    // MARK: - 用例 1：request 后、confirm 前不落库

    func test_request后confirm前_任务落库层面未完成且pending可见() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let task = try repo.createTask(title: "写周报")

        coordinator.requestCompletion(taskID: task.id, source: .taskList, in: repo)

        XCTAssertFalse(repo.findTask(by: task.id)?.completed ?? true, "confirm 前任务不应落库完成")
        XCTAssertEqual(coordinator.pending?.taskID, task.id)
        XCTAssertEqual(coordinator.pending?.source, .taskList)
        XCTAssertEqual(timer.scheduleCount, 1, "应恰好开一个撤回窗口")
    }

    // MARK: - 用例 2：计时到 confirm 普通任务落库

    func test_计时到confirm_普通任务落库完成_lastConfirmed置位_pending清空() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let task = try repo.createTask(title: "写周报")

        coordinator.requestCompletion(taskID: task.id, source: .taskList, in: repo)
        timer.fireNow()

        XCTAssertTrue(repo.findTask(by: task.id)?.completed ?? false, "confirm 后任务应落库完成")
        XCTAssertEqual(coordinator.lastConfirmed?.taskID, task.id)
        XCTAssertEqual(coordinator.lastConfirmed?.generatedNextOccurrence, false)
        XCTAssertNil(coordinator.pending)
    }

    // MARK: - 用例 3：重复任务 confirm 生成下一实例

    func test_重复任务confirm_生成下一实例_generatedNextOccurrence为真() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let task = try repo.createTask(title: "倒垃圾", dueDate: Date())
        _ = try repo.createRepeatRule(type: .daily, for: task)

        coordinator.requestCompletion(taskID: task.id, source: .taskList, in: repo)
        timer.fireNow()

        XCTAssertTrue(repo.findTask(by: task.id)?.completed ?? false)
        XCTAssertEqual(coordinator.lastConfirmed?.taskID, task.id)
        XCTAssertEqual(coordinator.lastConfirmed?.generatedNextOccurrence, true, "重复任务 confirm 应生成下一实例")
    }

    // MARK: - 用例 4：undo 恢复触发子任务、保留其他勾选

    func test_undo_pending清空_触发子任务恢复原值_其他子任务勾选保留() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let (task, items) = try makeTaskWithItems(["桌面", "地面", "衣柜"])

        // 前两项先勾上（历史进度），第三项是「本次刚勾选且因此 allChecked」的触发子任务
        try repo.toggleCheckItem(items[0])
        try repo.toggleCheckItem(items[1])
        try repo.toggleCheckItem(items[2])
        coordinator.requestCompletion(
            taskID: task.id,
            source: .taskList,
            trigger: (checkItemID: items[2].id, wasChecked: false),
            in: repo
        )

        coordinator.undo(in: repo)

        XCTAssertNil(coordinator.pending)
        XCTAssertFalse(repo.findTask(by: task.id)?.completed ?? true, "撤回后任务不应完成")
        XCTAssertFalse(checkItems(of: task)[2].isChecked, "触发子任务应恢复为勾选前状态")
        XCTAssertTrue(checkItems(of: task)[0].isChecked, "其他已勾子任务应保留")
        XCTAssertTrue(checkItems(of: task)[1].isChecked, "其他已勾子任务应保留")
    }

    // MARK: - 用例 5：连续完成两项，第一项显式确认

    func test_连续完成两项_第一项显式确认落库_第二项进入撤回窗口() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let taskA = try repo.createTask(title: "任务A")
        let taskB = try repo.createTask(title: "任务B")

        coordinator.requestCompletion(taskID: taskA.id, source: .taskList, in: repo)
        coordinator.requestCompletion(taskID: taskB.id, source: .taskList, in: repo)

        XCTAssertTrue(repo.findTask(by: taskA.id)?.completed ?? false, "连续完成时任务A 应被显式确认落库")
        XCTAssertEqual(coordinator.lastConfirmed?.taskID, taskA.id, "lastConfirmed 应指向被显式确认的任务A")
        XCTAssertEqual(coordinator.pending?.taskID, taskB.id, "撤回窗口应指向任务B")
        XCTAssertFalse(repo.findTask(by: taskB.id)?.completed ?? true, "任务B 仍在窗口内不应落库")
    }

    // MARK: - 用例 6：同任务重复 request 幂等

    func test_同任务重复request_幂等不重复开窗() throws {
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let task = try repo.createTask(title: "写周报")

        coordinator.requestCompletion(taskID: task.id, source: .taskList, in: repo)
        coordinator.requestCompletion(taskID: task.id, source: .taskDetail, in: repo)

        XCTAssertEqual(timer.scheduleCount, 1, "同任务重复 request 不应重开撤回窗口")
        XCTAssertEqual(coordinator.pending?.taskID, task.id)

        timer.fireNow()
        XCTAssertTrue(repo.findTask(by: task.id)?.completed ?? false, "窗口到期仍应正常确认一次")
    }

    // MARK: - 用例 7：confirm 落库失败暴露 lastFailure

    /// 失败注入手段：TodoRepository 非封闭类，测试子类覆写 completeTask 抛错；
    /// 协调层 confirm 走仓储公开 API，无需为测试改动生产代码。
    private enum TestSaveError: Error { case confirmFailed }

    private final class FailingSaveTodoRepository: TodoRepository {
        override func completeTask(_ task: TodoTask) throws {
            throw TestSaveError.confirmFailed
        }
    }

    func test_confirm落库失败_置lastFailure_任务未完成_pending清空() throws {
        let failingRepo = FailingSaveTodoRepository(context: CoreDataTestSupport.sharedTestContainer.viewContext)
        CoreDataTestSupport.retain(failingRepo)
        let timer = FakeConfirmTimer()
        let coordinator = makeCoordinator(timer: timer)
        let task = try failingRepo.createTask(title: "写周报")

        coordinator.requestCompletion(taskID: task.id, source: .taskList, in: failingRepo)
        timer.fireNow()

        XCTAssertNil(coordinator.pending, "失败后撤回窗口应关闭")
        XCTAssertFalse(failingRepo.findTask(by: task.id)?.completed ?? true, "落库失败任务不应被标记完成")
        XCTAssertEqual(coordinator.lastFailure?.taskID, task.id, "失败必须暴露到 lastFailure 供 UI 提示")
        XCTAssertNotNil(coordinator.lastFailure?.message)
        XCTAssertNil(coordinator.lastConfirmed, "失败不应置成功回执")
    }
}
