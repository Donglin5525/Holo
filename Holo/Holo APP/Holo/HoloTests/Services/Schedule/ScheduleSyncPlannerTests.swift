//
//  ScheduleSyncPlannerTests.swift
//  HoloTests
//
//  任务↔日历镜像对账决策核心单测（设计稿二期第 6 节全部规则）
//

import XCTest
@testable import Holo

final class ScheduleSyncPlannerTests: XCTestCase {

    private let now = Date()

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.day! += day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String = "跑步",
        start: Date? = nil,
        end: Date? = nil,
        completed: Bool = false,
        deleted: Bool = false,
        archived: Bool = false,
        updatedAt: Date? = nil
    ) -> SyncTaskSnapshot {
        SyncTaskSnapshot(
            taskId: id,
            title: title,
            plannedStart: start,
            plannedEnd: end,
            completed: completed,
            deleted: deleted,
            archived: archived,
            updatedAt: updatedAt ?? now
        )
    }

    private func makeEvent(
        id: String = "EVT-1",
        claimedTaskId: UUID? = nil,
        title: String = "跑步",
        start: Date? = nil,
        end: Date? = nil,
        modified: Date? = nil
    ) -> SyncEventSnapshot {
        SyncEventSnapshot(
            eventIdentifier: id,
            claimedTaskId: claimedTaskId,
            title: title,
            startDate: start ?? date(10),
            endDate: end ?? date(12),
            lastModifiedDate: modified ?? now
        )
    }

    private func makeMirror(
        taskId: UUID,
        eventIdentifier: String? = "EVT-1",
        state: String = "active",
        start: Date? = nil,
        end: Date? = nil,
        title: String = "跑步",
        confirmedAt: Date? = nil
    ) -> SyncMirrorSnapshot {
        SyncMirrorSnapshot(
            taskId: taskId,
            eventIdentifier: eventIdentifier,
            state: state,
            lastSyncedStart: start ?? date(10),
            lastSyncedEnd: end ?? date(12),
            lastSyncedTitle: title,
            lastSyncedAt: now,
            lastConfirmedAt: confirmedAt ?? now
        )
    }

    // MARK: - 建事件

    func test_无映射的带时间段任务_建事件() {
        let task = makeTask(start: date(10), end: date(12))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [], now: now)

        XCTAssertEqual(ops, [.createEvent(task: task)])
    }

    func test_已完成的带时间段任务_不回灌建事件() {
        let task = makeTask(start: date(10), end: date(12), completed: true)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [], now: now)

        XCTAssertTrue(ops.isEmpty, "写入开关开启时不向日历倾倒历史完成任务")
    }

    func test_无时间段任务_不建事件() {
        let task = makeTask(start: nil, end: nil)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [], now: now)

        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - 删事件

    func test_任务删除_删事件删映射() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12), deleted: true)
        let mirror = makeMirror(taskId: taskId)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [makeEvent()], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.deleteEventAndMirror(eventIdentifier: "EVT-1", taskId: taskId)])
    }

    func test_任务清时间段_删事件删映射() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: nil, end: nil)
        let mirror = makeMirror(taskId: taskId)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [makeEvent()], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.deleteEventAndMirror(eventIdentifier: "EVT-1", taskId: taskId)])
    }

    // MARK: - 完成

    func test_任务完成_事件保留不动() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12), completed: true)
        let mirror = makeMirror(taskId: taskId)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [makeEvent()], mirrors: [mirror], now: now)

        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - 单边跟随

    func test_任务侧改时间_更新事件() {
        let taskId = UUID()
        let task = makeTask(id: taskId, title: "长跑", start: date(9), end: date(11))
        let mirror = makeMirror(taskId: taskId)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [makeEvent()], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.updateEvent(task: task, eventIdentifier: "EVT-1")])
    }

    func test_事件侧改时间_回流任务() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12), updatedAt: date(8))
        let mirror = makeMirror(taskId: taskId)
        let event = makeEvent(start: date(14), end: date(16), modified: date(9))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.updateTask(taskId: taskId, title: "跑步", plannedStart: event.startDate, plannedEnd: event.endDate)])
    }

    func test_事件侧改_任务已完成_不回流() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12), completed: true, updatedAt: date(8))
        let mirror = makeMirror(taskId: taskId)
        let event = makeEvent(start: date(14), end: date(16), modified: date(9))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertTrue(ops.isEmpty, "已完成任务是历史，日历侧改动不回流")
    }

    // MARK: - 冲突（双边变，新者胜）

    func test_双边变_任务更新_任务胜() {
        let taskId = UUID()
        let task = makeTask(id: taskId, title: "新任务名", start: date(9), end: date(11), updatedAt: date(12))
        let mirror = makeMirror(taskId: taskId)
        let event = makeEvent(title: "新事件名", start: date(14), end: date(16), modified: date(10))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.updateEvent(task: task, eventIdentifier: "EVT-1")])
    }

    func test_双边变_事件更新_事件胜() {
        let taskId = UUID()
        let task = makeTask(id: taskId, title: "新任务名", start: date(9), end: date(11), updatedAt: date(10))
        let mirror = makeMirror(taskId: taskId)
        let event = makeEvent(title: "新事件名", start: date(14), end: date(16), modified: date(12))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.updateTask(taskId: taskId, title: "新事件名", plannedStart: event.startDate, plannedEnd: event.endDate)])
    }

    // MARK: - 认领与断开

    func test_认领不到_宽限内_不操作() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12))
        let mirror = makeMirror(taskId: taskId, confirmedAt: now.addingTimeInterval(-60))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [mirror], now: now)

        XCTAssertTrue(ops.isEmpty, "宽限期内等 iCloud 同步，不重建也不断开")
    }

    func test_认领不到_超宽限_断开且不重建() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12))
        let mirror = makeMirror(taskId: taskId, confirmedAt: now.addingTimeInterval(-ScheduleSyncPlanner.claimGraceInterval - 1))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.disconnectMirror(taskId: taskId)], "超宽限断开，且断开后不得自动重建事件")
    }

    func test_eventIdentifier漂移_按埋入任务ID认领_回流() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12), updatedAt: date(8))
        // 映射记录旧 identifier；事件已换新 identifier 但 url 埋的任务 ID 不变
        let mirror = makeMirror(taskId: taskId, eventIdentifier: "OLD-ID")
        let event = makeEvent(id: "NEW-ID", claimedTaskId: taskId, start: date(14), end: date(16), modified: date(9))
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertEqual(ops, [.updateTask(taskId: taskId, title: "跑步", plannedStart: event.startDate, plannedEnd: event.endDate)])
    }

    func test_断开映射的任务_不自动重建事件() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12))
        let mirror = makeMirror(taskId: taskId, state: "disconnected")
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [], mirrors: [mirror], now: now)

        XCTAssertTrue(ops.isEmpty, "用户在日历删过镜像事件，删了不能又冒出来")
    }

    func test_多设备幂等_映射在事件在_无操作() {
        let taskId = UUID()
        let task = makeTask(id: taskId, start: date(10), end: date(12))
        // 另一设备建的映射（本设备视角 identifier 相同、值全一致）→ 不产生任何写操作
        let mirror = makeMirror(taskId: taskId, eventIdentifier: "EVT-1")
        let event = makeEvent(id: "EVT-1", claimedTaskId: taskId)
        let ops = ScheduleSyncPlanner.plan(tasks: [task], events: [event], mirrors: [mirror], now: now)

        XCTAssertTrue(ops.isEmpty)
    }
}
