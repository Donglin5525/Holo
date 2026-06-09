//
//  HealthDashboardStateTests.swift
//  HoloTests
//
//  健康模块展示状态测试
//

import XCTest
import HealthKit
@testable import Holo

final class HealthDashboardStateTests: XCTestCase {

    func testSleepSampleAggregatorDoesNotDoubleCountOverlappingStages() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 2))!
        let samples = [
            HealthSleepSampleAggregator.Interval(
                start: base,
                end: base.addingTimeInterval(6 * 3600)
            ),
            HealthSleepSampleAggregator.Interval(
                start: base,
                end: base.addingTimeInterval(2 * 3600)
            ),
            HealthSleepSampleAggregator.Interval(
                start: base.addingTimeInterval(2 * 3600),
                end: base.addingTimeInterval(4 * 3600)
            ),
            HealthSleepSampleAggregator.Interval(
                start: base.addingTimeInterval(4 * 3600),
                end: base.addingTimeInterval(6 * 3600)
            )
        ]

        XCTAssertEqual(HealthSleepSampleAggregator.totalHours(for: samples), 6, accuracy: 0.001)
    }

    func testStandHourAggregatorCountsUniqueHours() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 9))!
        let window = HealthSleepSampleAggregator.Interval(
            start: calendar.startOfDay(for: base),
            end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: base))!
        )
        let samples = [
            HKCategorySample(
                type: HKObjectType.categoryType(forIdentifier: .appleStandHour)!,
                value: HKCategoryValueAppleStandHour.stood.rawValue,
                start: base,
                end: base.addingTimeInterval(3600)
            ),
            HKCategorySample(
                type: HKObjectType.categoryType(forIdentifier: .appleStandHour)!,
                value: HKCategoryValueAppleStandHour.stood.rawValue,
                start: base.addingTimeInterval(20 * 60),
                end: base.addingTimeInterval(3600)
            ),
            HKCategorySample(
                type: HKObjectType.categoryType(forIdentifier: .appleStandHour)!,
                value: HKCategoryValueAppleStandHour.stood.rawValue,
                start: base.addingTimeInterval(3600),
                end: base.addingTimeInterval(2 * 3600)
            )
        ]

        XCTAssertEqual(HealthStandHourAggregator.stoodHours(for: samples, in: window), 2)
    }

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
