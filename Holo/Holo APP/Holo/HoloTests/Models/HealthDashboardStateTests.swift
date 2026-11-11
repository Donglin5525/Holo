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
            workout: HealthMetricSnapshot(type: .workout, value: 45, availability: .available),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 18, availability: .available),
            dataSourceState: .connected
        )

        // 运动不参与身体分数（45 分钟满进度但分数与三指标口径一致）
        XCTAssertEqual(snapshot.bodyScore, 94)
    }

    func testBodyScoreIsNilWhenNoReliableDataExists() {
        let snapshot = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 0, availability: .noData),
            sleep: HealthMetricSnapshot(type: .sleep, value: 0, availability: .noData),
            workout: HealthMetricSnapshot(type: .workout, value: 0, availability: .noData),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 0, availability: .unsupported),
            dataSourceState: .connected
        )

        XCTAssertNil(snapshot.bodyScore)
        XCTAssertEqual(snapshot.bodyScoreText, "--")
        XCTAssertEqual(snapshot.statusTitle, "等待健康数据")
        XCTAssertEqual(snapshot.verdictText, "Apple Health 里还没有这一天的记录。")
    }

    /// 至少两项有数据才出分：单项折算=单项完成度，走满一万步就 100 分不代表身体状态
    func testBodyScoreRequiresAtLeastTwoReliableMetrics() {
        let stepsOnly = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 10_000, availability: .available),
            sleep: HealthMetricSnapshot(type: .sleep, value: 0, availability: .noData),
            workout: HealthMetricSnapshot(type: .workout, value: 0, availability: .noData),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 0, availability: .noData),
            dataSourceState: .connected
        )

        XCTAssertNil(stepsOnly.bodyScore)
        XCTAssertEqual(stepsOnly.statusTitle, "数据不全")
        XCTAssertEqual(stepsOnly.verdictText, "只有步数有记录，暂不计算身体分。")
        XCTAssertNil(stepsOnly.scoringBadgeText)

        // 两项可用即出分；缺项时徽章必须注明按几项算
        let twoItems = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 10_000, availability: .available),
            sleep: HealthMetricSnapshot(type: .sleep, value: 8, availability: .available),
            workout: HealthMetricSnapshot(type: .workout, value: 0, availability: .noData),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 0, availability: .noData),
            dataSourceState: .connected
        )

        XCTAssertNotNil(twoItems.bodyScore)
        XCTAssertEqual(twoItems.scoringRingCount, 2)
        XCTAssertEqual(twoItems.scoringBadgeText, "按 2 项算")
        // 参与打分的两项都达标，但缺站立不说「三环全部达标」
        XCTAssertEqual(twoItems.verdictText, "步数、睡眠已达标。")
    }

    /// 阅读动线（睡眠优先）：指标行为 睡眠→步数→运动→站立
    func testMetricsOrderIsSleepFirst() {
        let snapshot = HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: 10_000, availability: .available),
            sleep: HealthMetricSnapshot(type: .sleep, value: 8, availability: .available),
            workout: HealthMetricSnapshot(type: .workout, value: 30, availability: .available),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: 12, availability: .available),
            dataSourceState: .connected
        )

        XCTAssertEqual(snapshot.metrics.map(\.type), [.sleep, .steps, .workout, .standHours])
        XCTAssertEqual(snapshot.ringMetrics.count, 3)
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

    // MARK: - 今天卡判词（方案 A：一句话说清达标了什么、差在哪）

    private func makeRingSnapshot(
        steps: Double,
        sleep: Double,
        stand: Double
    ) -> HealthDashboardSnapshot {
        HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: steps, availability: steps > 0 ? .available : .noData),
            sleep: HealthMetricSnapshot(type: .sleep, value: sleep, availability: sleep > 0 ? .available : .noData),
            workout: HealthMetricSnapshot(type: .workout, value: 0, availability: .noData),
            standOrActivity: HealthMetricSnapshot(type: .standHours, value: stand, availability: stand > 0 ? .available : .noData),
            dataSourceState: .connected
        )
    }

    func testVerdictNamesMetMetricsAndWorstGap() {
        // 步数、站立达标，睡眠 7/8 差 1 小时（整数小时不带小数）
        let snapshot = makeRingSnapshot(steps: 10_000, sleep: 7, stand: 12)
        XCTAssertEqual(snapshot.verdictText, "步数、站立已达标，睡眠还差 1 小时。")
        // 分行版：达标一句、差距一句（整段换行会把「睡眠」拆开）
        XCTAssertEqual(snapshot.verdictClauses, ["步数、站立已达标，", "睡眠还差 1 小时。"])
        XCTAssertEqual(snapshot.scoringBadgeText, "按 3 项算")
    }

    func testVerdictWhenNothingMetSpeaksGapOnly() {
        // 三项都没达标：完成度最低的是步数（0.3），判词只说它差多少
        let snapshot = makeRingSnapshot(steps: 3_000, sleep: 5, stand: 4)
        XCTAssertEqual(snapshot.verdictText, "步数还差 7,000 步。")
    }

    func testVerdictWhenAllRingMetricsMet() {
        let snapshot = makeRingSnapshot(steps: 10_000, sleep: 8, stand: 12)
        XCTAssertEqual(snapshot.verdictText, "三环全部达标。")
    }

    func testGapTextFormats() {
        // 步数差值向上取整、千分位
        XCTAssertEqual(
            HealthMetricSnapshot(type: .steps, value: 8_400, availability: .available).gapText,
            "1,600 步"
        )
        // 半小时保留一位小数
        XCTAssertEqual(
            HealthMetricSnapshot(type: .sleep, value: 7.5, availability: .available).gapText,
            "0.5 小时"
        )
        // 已达标无差值
        XCTAssertNil(HealthMetricSnapshot(type: .standHours, value: 12, availability: .available).gapText)
    }

}
