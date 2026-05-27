//
//  HealthDashboardStateTests.swift
//  HoloTests
//
//  健康模块展示状态测试
//

import XCTest
@testable import Holo

final class HealthDashboardStateTests: XCTestCase {

    func testBodyScoreUsesWeightedProgressAndCapsAtOneHundred() {
        let snapshot = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 8_000, availability: .available),
            sleep: HealthMetricSnapshot(type: .sleep, value: 8, availability: .available),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 18, availability: .available),
            dataSourceState: .connected
        )

        XCTAssertEqual(snapshot.bodyScore, 94)
    }

    func testBodyScoreIsNilWhenNoReliableDataExists() {
        let snapshot = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 0, availability: .noData),
            sleep: HealthMetricSnapshot(type: .sleep, value: 0, availability: .noData),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 0, availability: .unsupported),
            dataSourceState: .connected
        )

        XCTAssertNil(snapshot.bodyScore)
        XCTAssertEqual(snapshot.bodyScoreText, "数据不足")
    }

    func testStandFallbackUsesActiveMinutesWhenStandIsUnsupported() {
        let fallback = HealthDashboardSnapshot.standOrActivitySnapshot(
            standHours: 0,
            activeMinutes: 24,
            standAvailability: .unsupported
        )

        XCTAssertEqual(fallback.type, .activeMinutes)
        XCTAssertEqual(fallback.value, 24)
        XCTAssertEqual(fallback.availability, .available)
        XCTAssertEqual(fallback.title, "活动")
    }

    func testConnectedDataSourceCopyMentionsReadOnlySync() {
        XCTAssertEqual(HealthDataSourceState.connected.title, "Apple Health 已连接")
        XCTAssertEqual(HealthDataSourceState.connected.subtitle, "只读同步 · 步数 / 睡眠 / 站立")
        XCTAssertEqual(HealthDataSourceState.connected.badgeText, "在线")
    }
}
