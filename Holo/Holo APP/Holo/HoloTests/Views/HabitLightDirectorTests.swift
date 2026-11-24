//
//  HabitLightDirectorTests.swift
//  HoloTests
//
//  2026-11-23 审美七项 P1：光归处导演状态机——
//  不可飞只点亮没有飞行；落地（或兜底超时）放行页头小灯并移除飞行；
//  撤销打卡把点火 / 飞行 / 占位清干净。
//  时序参数全部注入极短值，不真等 1.2 秒。
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
