//
//  TaskQuadrantMovePolicyTests.swift
//  HoloTests
//
//  象限移动唯一写入规则（多视图方案 §6.2 表 / 验收 Q02/Q03/Q04）：
//  同格 no-op、两轴补丁、P2/P3 保留、unknown 目标映射。
//

import XCTest
@testable import Holo

final class TaskQuadrantMovePolicyTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 2026-10-16 11:00（§11 演示时钟）
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 11))!
    }

    private func due(_ d: Int, _ h: Int = 0, allDay: Bool = false) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: allDay ? 0 : h))!
    }

    private func patch(
        target: TaskQuadrant,
        importance: TaskImportance,
        urgencyMode: TaskUrgencyMode,
        effectiveDue: Date?
    ) -> TaskQuadrantMovePolicy.Patch? {
        TaskQuadrantMovePolicy.patch(
            target: target,
            importance: importance,
            urgencyMode: urgencyMode,
            effectiveDue: effectiveDue,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Q02：同格 no-op

    func testSameQuadrantIsNoOp() {
        // B：P1 / auto / 20 日全天截止 → 解析为留出时间；移到留出时间 = no-op
        XCTAssertNil(patch(target: .scheduleTime, importance: .p1, urgencyMode: .auto, effectiveDue: due(20, allDay: true)))
        // C：P2 / auto / 16 日全天 → 集中处理；移到集中处理 = no-op
        XCTAssertNil(patch(target: .batchHandle, importance: .p2, urgencyMode: .auto, effectiveDue: due(16, allDay: true)))
    }

    // MARK: - Q03：B 跨格移动

    func testBMoveToDoFirstWritesBothAxes() {
        let result = patch(target: .doFirst, importance: .p1, urgencyMode: .auto, effectiveDue: due(20, allDay: true))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p1, urgencyMode: .p1))
    }

    func testMoveToScheduleTimeConvertsAutoToManualP3() {
        // A：P1 / auto / 16 日（解析优先处理）→ 移留出时间：重要保持 P1，紧急 auto → 手动 P3
        let result = patch(target: .scheduleTime, importance: .p1, urgencyMode: .auto, effectiveDue: due(16, 18))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p1, urgencyMode: .p3))
    }

    func testManualP2UrgencyPreservedWhenMovingToScheduleTime() {
        // P2 + 手动 P2 + 今天截止（解析集中处理）→ 移留出时间：重要性升 P1、手动 P2 保留不被改 P3
        let result = patch(target: .scheduleTime, importance: .p2, urgencyMode: .p2, effectiveDue: due(16, 17))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p1, urgencyMode: .p2))
    }

    // MARK: - Q04：P2/P3 保留（非重要侧不硬改成同一档）

    func testBatchHandleKeepsExistingP3() {
        // D：P3 / auto / 31 日 → 解析稍后再看；移集中处理：P3 保留，紧急 → 手动 P1
        let result = patch(target: .batchHandle, importance: .p3, urgencyMode: .auto, effectiveDue: due(31, allDay: true))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p3, urgencyMode: .p1))
    }

    func testP1ToBatchHandleFallsToNeutralP2() {
        // P1 移集中处理：重要性降为中性 P2（不是 P3）
        let result = patch(target: .batchHandle, importance: .p1, urgencyMode: .auto, effectiveDue: due(20, allDay: true))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p2, urgencyMode: .p1))
    }

    func testReviewLaterKeepsP2AndManualizesUrgency() {
        // P2 + 手动 P1 + 今天截止（解析集中处理）→ 移稍后再看：重要性 P2 保留、紧急 P1 → 手动 P3
        let result = patch(target: .reviewLater, importance: .p2, urgencyMode: .p1, effectiveDue: due(16, 17))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p2, urgencyMode: .p3))
    }

    func testP3AutoToReviewLaterKeepsP3AndManualizesUrgency() {
        // P3 + auto + 今天截止（解析集中处理）→ 移稍后再看：P3 保留、紧急转手动 P3
        let result = patch(target: .reviewLater, importance: .p3, urgencyMode: .auto, effectiveDue: due(16, 17))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p3, urgencyMode: .p3))
    }

    // MARK: - unknown 移动

    func testUnknownMoveToDoFirstBecomesP1ManualP1() {
        let result = patch(target: .doFirst, importance: .unknown, urgencyMode: .auto, effectiveDue: due(16, 17))
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p1, urgencyMode: .p1))
    }

    func testUnknownToReviewLaterBecomesNeutralP2ManualP3() {
        let result = patch(target: .reviewLater, importance: .unknown, urgencyMode: .auto, effectiveDue: nil)
        XCTAssertEqual(result, TaskQuadrantMovePolicy.Patch(importance: .p2, urgencyMode: .p3))
    }

    // MARK: - 待整理不是移动目标

    func testUnclassifiedTargetReturnsNil() {
        XCTAssertNil(patch(target: .unclassified, importance: .p1, urgencyMode: .auto, effectiveDue: nil))
    }
}
