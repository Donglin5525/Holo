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

    // MARK: - 健康洞察基线（LLM 生成改造前的稳定 fallback 行为）
    // 审查修订 P13：coreInsight 三档只锁结构 + 分档区分性，不逐字锁文案；
    // lifestyleInsights 只锁条数与 domain 顺序，文案后续交 FallbackBuilder 统一管理。

    private func makeHealthSnapshot(
        sleepValue: Double,
        sleepAvailability: HealthMetricAvailability
    ) -> HealthDashboardSnapshot {
        HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 6_000, availability: .available),
            sleep: HealthMetricSnapshot(type: .sleep, value: sleepValue, availability: sleepAvailability),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 10, availability: .available),
            dataSourceState: .connected
        )
    }

    func testCoreInsightHasStableTitleAndThreeDistinctBranches() {
        let high = makeHealthSnapshot(sleepValue: 8, sleepAvailability: .available).coreInsight
        let low = makeHealthSnapshot(sleepValue: 6, sleepAvailability: .available).coreInsight
        let noData = makeHealthSnapshot(sleepValue: 0, sleepAvailability: .noData).coreInsight

        // 标题稳定（三档共用）
        XCTAssertEqual(high.title, "今日核心洞察")
        XCTAssertEqual(low.title, "今日核心洞察")
        XCTAssertEqual(noData.title, "今日核心洞察")

        // 三档文案互不相同、均非空（区分性断言，不锁具体措辞）
        XCTAssertFalse(high.detail.isEmpty)
        XCTAssertFalse(low.detail.isEmpty)
        XCTAssertFalse(noData.detail.isEmpty)
        XCTAssertNotEqual(high.detail, low.detail)
        XCTAssertNotEqual(low.detail, noData.detail)
        XCTAssertNotEqual(high.detail, noData.detail)
    }

}
