//
//  HabitLightDirectorTests.swift
//  HoloTests
//
//  2026-11-23 审美七项 P1：光归处导演状态机——
//  不可飞只点亮没有飞行；落地（或兜底超时）放行页头小灯并移除飞行；
//  撤销打卡把点火 / 飞行 / 占位清干净。
//  时序参数全部注入极短值，不真等 1.2 秒。
//  2026-11-25：起飞决策——页头小灯看得见飞向小灯，被滚出视口往上飞走（东林拍板）。
//

import XCTest
import SwiftUI
@testable import Holo

@MainActor
final class HabitLightDirectorTests: XCTestCase {

    private func makeEvent() -> HoloMotionEvent {
        HoloMotionEvent(operationID: UUID(),
                        subject: HoloMotionSubject(domain: .habit, id: UUID()),
                        phase: .confirmed,
                        occurredAt: Date())
    }

    private func makePlan() -> HabitLightFlightPlan {
        HabitLightFlightPlan(start: CGPoint(x: 300, y: 400), end: CGPoint(x: 60, y: 40))
    }

    // MARK: 用例

    func test_不可飞_只有行内点亮没有飞行() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.3)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue, flight: nil)

        XCTAssertNotNil(director.ignitions[habitId], "不可飞也要点亮行内灯")
        XCTAssertTrue(director.flights.isEmpty)
        XCTAssertTrue(director.pendingLanding.isEmpty)

        try await Task.sleep(for: .seconds(0.1))
        XCTAssertTrue(director.flights.isEmpty, "没有飞行计划就不会凭空起飞")
        XCTAssertTrue(director.pendingLanding.isEmpty, "页头小灯不被占住，随数据直接亮")
    }

    func test_飞行落地_移除飞行并放行页头小灯() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.3)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue, flight: makePlan())
        XCTAssertTrue(director.pendingLanding.contains(habitId),
                      "一拿到事件就压住页头小灯，不能等起飞才压（否则小灯会先亮一下再熄灭）")
        XCTAssertTrue(director.flights.isEmpty, "起飞延迟之内光点还没出现")

        try await Task.sleep(for: .seconds(0.08))
        XCTAssertEqual(director.flights.count, 1, "起飞延迟后光点在飞")
        XCTAssertTrue(director.pendingLanding.contains(habitId), "落地前页头小灯被压住")

        let flightID = try XCTUnwrap(director.flights.first?.id)
        director.land(flightID)
        XCTAssertTrue(director.flights.isEmpty, "落地即移除飞行")
        XCTAssertFalse(director.pendingLanding.contains(habitId), "落地放行页头小灯")
        XCTAssertNotNil(director.ignitions[habitId], "落地不清行内灯（已点亮是终态）")

        // 落地后兜底定时器不得复活占位
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(director.pendingLanding.isEmpty)
        XCTAssertTrue(director.flights.isEmpty)
    }

    func test_飞行未落地_兜底超时后清空占位() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.2)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue, flight: makePlan())

        try await Task.sleep(for: .seconds(0.08))
        XCTAssertTrue(director.pendingLanding.contains(habitId), "兜底前占位仍在")
        XCTAssertEqual(director.flights.count, 1)

        try await Task.sleep(for: .seconds(0.2))
        XCTAssertTrue(director.pendingLanding.isEmpty, "兜底超时后放行页头小灯，不能永远不亮")
        XCTAssertTrue(director.flights.isEmpty, "兜底同时移除残留飞行")
    }

    func test_撤销打卡_点火飞行与占位全部清干净() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.2)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue, flight: makePlan())

        try await Task.sleep(for: .seconds(0.08))
        director.cancel(habitId: habitId)
        XCTAssertNil(director.ignitions[habitId])
        XCTAssertTrue(director.flights.isEmpty)
        XCTAssertTrue(director.pendingLanding.isEmpty)

        // 取消之后兜底定时器也不得复活任何状态
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertNil(director.ignitions[habitId])
        XCTAssertTrue(director.flights.isEmpty)
        XCTAssertTrue(director.pendingLanding.isEmpty)
    }

    func test_进后台_清掉进行中的飞行与占位_保留行内点亮() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.3)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue, flight: makePlan())

        try await Task.sleep(for: .seconds(0.08))
        director.clearTransient()
        XCTAssertTrue(director.flights.isEmpty, "后台清飞行")
        XCTAssertTrue(director.pendingLanding.isEmpty, "后台清占位")
        XCTAssertNotNil(director.ignitions[habitId], "行内点亮令牌保留（回到前台仍是已点亮终态）")

        try await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(director.pendingLanding.isEmpty)
    }

    func test_往上飞走_照常起飞_页头小灯照常等到飞完才放行() async throws {
        let director = HabitLightDirector(flightDelay: 0.01, landingTimeout: 0.3)
        let habitId = UUID()
        director.handle(event: makeEvent(), habitId: habitId, color: .blue,
                        flight: HabitLightFlightPlan(start: CGPoint(x: 300, y: 520), end: CGPoint(x: 300, y: 338),
                                                     kind: .upward))

        try await Task.sleep(for: .seconds(0.08))
        XCTAssertEqual(director.flights.first?.kind, .upward)
        XCTAssertTrue(director.pendingLanding.contains(habitId), "飞完之前页头小灯仍被压住")
    }

    // MARK: 起飞决策

    func test_起飞决策_小灯完整可见时飞向小灯() {
        let plan = HabitLightDirector.flightPlan(
            start: CGPoint(x: 300, y: 400), destination: CGPoint(x: 60, y: 40), tallyCount: 5,
            stage: HabitLightStage(tallyIsFullyVisible: true, contentTopInViewport: 4))

        XCTAssertEqual(plan, HabitLightFlightPlan(start: CGPoint(x: 300, y: 400),
                                                  end: CGPoint(x: 60, y: 40), kind: .toTally))
    }

    func test_起飞决策_小灯滚出视口时往上飞_终点停在屏幕顶边下方() {
        // 往下滚了 320：内容顶边在视口里的位置是 -320，视口顶边换到内容坐标里就是 320
        let plan = HabitLightDirector.flightPlan(
            start: CGPoint(x: 300, y: 520), destination: nil, tallyCount: 5,
            stage: HabitLightStage(tallyIsFullyVisible: false, contentTopInViewport: -320))

        XCTAssertEqual(plan, HabitLightFlightPlan(start: CGPoint(x: 300, y: 520),
                                                  end: CGPoint(x: 300, y: 320 + HabitLightGeometry.topFadeMargin),
                                                  kind: .upward),
                       "不需要小灯的位置也能起飞；横向不动，纵向停在顶边下方留出淡尽的距离")
    }

    func test_小灯可见的判定_只剩一条边也算滚出去() {
        XCTAssertFalse(HabitLightGeometry.tallyIsFullyVisible(topInViewport: -0.5))
        XCTAssertTrue(HabitLightGeometry.tallyIsFullyVisible(topInViewport: 0))
        XCTAssertTrue(HabitLightGeometry.tallyIsFullyVisible(topInViewport: 12))
    }

    func test_起飞决策_没有小灯排或拿不到起点时不飞() {
        let scrolled = HabitLightStage(tallyIsFullyVisible: false, contentTopInViewport: -320)
        XCTAssertNil(HabitLightDirector.flightPlan(start: nil, destination: nil, tallyCount: 5, stage: scrolled),
                     "拿不到起点（行被回收 / 文件夹折叠）")
        XCTAssertNil(HabitLightDirector.flightPlan(start: CGPoint(x: 300, y: 520), destination: nil,
                                                   tallyCount: HabitTodayLightsMetrics.maxLampCount + 1, stage: scrolled),
                     "小灯超过上限只留文字，没有归处")
        XCTAssertNil(HabitLightDirector.flightPlan(start: CGPoint(x: 300, y: 520), destination: nil,
                                                   tallyCount: 0, stage: scrolled),
                     "没有好习惯就没有小灯排")
    }

    func test_起飞决策_小灯可见却拿不到小灯位置时不飞() {
        let plan = HabitLightDirector.flightPlan(
            start: CGPoint(x: 300, y: 400), destination: nil, tallyCount: 5,
            stage: HabitLightStage(tallyIsFullyVisible: true, contentTopInViewport: 4))
        XCTAssertNil(plan)
    }

    func test_往上飞走_灯离顶边太近时就地淡尽_不往下走() {
        // 灯中心在视口顶边下方 10，比淡尽余量还近：终点不能比起点低
        let end = HabitLightGeometry.upwardEnd(from: CGPoint(x: 300, y: 10), contentTopInViewport: 0)
        XCTAssertEqual(end, CGPoint(x: 300, y: 10))
    }

    func test_滚动位置键_没设过这个键的节点不会把量到的数冲掉() {
        // 合并时列表里大量节点不设这个键、带着默认值进来：量到的数必须在它们前后都还在
        var value: CGFloat? = nil
        HabitContentTopKey.reduce(value: &value) { nil }
        HabitContentTopKey.reduce(value: &value) { -364 }
        HabitContentTopKey.reduce(value: &value) { nil }
        XCTAssertEqual(value, -364, "「取下一个」的非可选写法会被默认值冲回 0（11-25 实拍踩过）")
    }

    func test_淡出_飞向小灯末段才淡_往上飞走后半程渐淡并到终点前淡尽() {
        XCTAssertEqual(HabitLightGeometry.opacity(progress: 0.5, fadeStart: HabitLightFlightKind.toTally.fadeStart), 1,
                       "飞向小灯：过了一半还是全亮")
        XCTAssertEqual(HabitLightGeometry.opacity(progress: 1, fadeStart: HabitLightFlightKind.upward.fadeStart), 0,
                       "往上飞走：到终点时已完全透明，顶边上不会出现被切一半的光点")
        let midway = HabitLightGeometry.opacity(progress: 0.75, fadeStart: HabitLightFlightKind.upward.fadeStart)
        XCTAssertGreaterThan(midway, 0)
        XCTAssertLessThan(midway, 1, "后半程是渐淡，不是突然消失")
    }

    // MARK: 路径几何纯函数

    func test_贝塞尔路径_端点与缓动边界() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        XCTAssertEqual(HabitLightGeometry.point(from: start, to: end, t: 0), start)
        let landed = HabitLightGeometry.point(from: start, to: end, t: 1)
        XCTAssertEqual(landed.x, end.x, accuracy: 0.001)
        XCTAssertEqual(landed.y, end.y, accuracy: 0.001)

        XCTAssertEqual(HabitLightGeometry.easeInOut(0), 0)
        XCTAssertEqual(HabitLightGeometry.easeInOut(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(HabitLightGeometry.easeInOut(1), 1)
        XCTAssertEqual(HabitLightGeometry.easeInOut(-0.2), 0, "越界截断到 0")
        XCTAssertEqual(HabitLightGeometry.easeInOut(1.5), 1, "越界截断到 1")
    }
}
