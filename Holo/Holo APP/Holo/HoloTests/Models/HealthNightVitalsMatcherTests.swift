//
//  HealthNightVitalsMatcherTests.swift
//  HoloTests
//
//  睡眠体征匹配器测试：区间外样本剔除（日间呼吸/睡前 HRV/正午运动心率）、
//  覆盖门槛（心率呼吸 ≥3、HRV ≥2）、前后两半各有样本、中位数计算。
//  完成条件真源：docs/health/plans/2026-11-17-Holo健康分析实施方案.md 第二步。
//

import Foundation
@testable import Holo

struct HealthNightVitalsMatcherTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test区间外样本不进入该晚统计()
        test覆盖门槛给中位数()
        test样本不足只作观测点()
        testHRV两样本前后半各一达标()
        test两半样本缺一半不达标()
        print("HealthNightVitalsMatcherTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func sample(_ offsetMinutes: Double, _ value: Double) -> HealthVitalSample {
        HealthVitalSample(date: base.addingTimeInterval(offsetMinutes * 60), value: value)
    }

    /// 23:00–02:00 + 03:00–07:00 两段可信睡着（累计 7h，中点分界在第二段开始后 30 分钟）
    private static let trusted: [HealthSleepSampleAggregator.Interval] = [
        HealthSleepSampleAggregator.Interval(start: base, end: base.addingTimeInterval(3 * 3600)),
        HealthSleepSampleAggregator.Interval(start: base.addingTimeInterval(4 * 3600), end: base.addingTimeInterval(8 * 3600))
    ]

    private static func test区间外样本不进入该晚统计() {
        let raw = [
            sample(-180, 71),     // 睡前心率（区间外）
            sample(30, 55), sample(90, 56), sample(150, 54),   // 第一段内
            sample(-1, 16)        // 白天呼吸（区间外）
        ]
        let result = HealthNightVitalsMatcher.match(raw: raw, trustedIntervals: trusted)
        expect(result.samples.count == 3, "区间外样本必须剔除，实际保留 \(result.samples.count) 个")
        expect(!result.samples.contains { $0.value == 71 || $0.value == 16 }, "睡前心率与白天呼吸不得混入")
    }

    private static func test覆盖门槛给中位数() {
        // 前半（第一段）1 个 + 后半（第二段）2 个 = 3 个，达门槛
        let raw = [sample(30, 55), sample(270, 57), sample(300, 56)]
        let result = HealthNightVitalsMatcher.match(raw: raw, trustedIntervals: trusted)
        expect(result.coverage == .sufficient, "3 个样本且前后两半有样本应达标")
        expect(result.median == 56, "中位数应为 56，实际 \(String(describing: result.median))")
    }

    private static func test样本不足只作观测点() {
        let raw = [sample(30, 55), sample(90, 56)]   // 2 个 < 3
        let result = HealthNightVitalsMatcher.match(raw: raw, trustedIntervals: trusted)
        expect(result.coverage == .observed, "2 个心率样本应为观测点")
        expect(result.median == nil, "观测点不给中位数")
        expect(result.samples.count == 2, "样本保留可查看")
    }

    private static func testHRV两样本前后半各一达标() {
        // 累计 7h：前半 3.5h 落在第一段末尾（180min）与第二段开头（240min）之间
        let raw = [sample(150, 42), sample(330, 38)]
        let result = HealthNightVitalsMatcher.match(raw: raw, trustedIntervals: trusted, isHRV: true)
        expect(result.coverage == .sufficient, "HRV 两个样本各在前后半应达标")
        expect(result.median == 40, "中位数应为 (42+38)/2=40，实际 \(String(describing: result.median))")
    }

    private static func test两半样本缺一半不达标() {
        let raw = [sample(30, 42), sample(90, 38)]   // 都在前半（第一段）
        let result = HealthNightVitalsMatcher.match(raw: raw, trustedIntervals: trusted, isHRV: true)
        expect(result.coverage == .observed, "HRV 两个样本都在前半不得给中位数")
        expect(result.median == nil, "后半无样本不给中位数")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        HealthNightVitalsMatcherTests.main()
    }
}
#endif
