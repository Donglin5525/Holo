//
//  SleepStructureAnalyzerTests.swift
//  HoloTests
//
//  睡眠结构特征计算器测试：REM 段数/潜伏期、深睡前半夜占比、入睡潜伏期、
//  重叠段合并、碎片过滤、无阶段降级为 nil。
//

import Foundation
@testable import Holo

struct SleepStructureAnalyzerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testREM计数与潜伏期()
        test重叠REM段合并为一段()
        test五分钟以下REM碎片不计段()
        test深睡前半夜占比()
        test深睡全在后半夜占比为零()
        test入睡潜伏期按在床到首次入睡计算()
        test无阶段数据时结构特征全部为nil()
        test无睡着段返回空特征()
        print("SleepStructureAnalyzerTests passed")
    }

    /// 固定基准时刻，分钟偏移构造分段
    fileprivate static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func interval(_ startMinutes: Double, _ endMinutes: Double)
        -> HealthSleepSampleAggregator.Interval {
        HealthSleepSampleAggregator.Interval(
            start: base.addingTimeInterval(startMinutes * 60),
            end: base.addingTimeInterval(endMinutes * 60)
        )
    }

    // MARK: - 用例

    private static func testREM计数与潜伏期() {
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(core: (17, 61))
            .deep(61, 105)
            .asleep(core: (105, 149))
            .deep(149, 192)
            .rem(192, 204)
            .asleep(core: (204, 240))
            .build()

        let features = SleepStructureAnalyzer.features(night)
        expect(features.remEpisodes == 1, "单段 REM 应计 1 段，实际 \(String(describing: features.remEpisodes))")
        expect(features.remLatencyMinutes == 175, "REM 潜伏期应为 175 分钟（入睡 17 分后第一段 REM 始于 192），实际 \(String(describing: features.remLatencyMinutes))")
        expect(features.sleepOnsetLatencyMinutes == 17, "入睡潜伏期应为 17 分钟")
        expect(features.deepFrontLoadPercent != nil, "有深睡段时应产出前半夜占比")
    }

    private static func test重叠REM段合并为一段() {
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(core: (17, 100))
            .rem(192, 204)
            .rem(200, 220)
            .rem(300, 320)
            .build()

        let features = SleepStructureAnalyzer.features(night)
        expect(features.remEpisodes == 2, "重叠 REM 段应合并后计数：[192,204)+[200,220) 合并 1 段 + [300,320) 1 段 = 2，实际 \(String(describing: features.remEpisodes))")
    }

    private static func test五分钟以下REM碎片不计段() {
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(core: (17, 100))
            .rem(120, 123)
            .rem(200, 220)
            .build()

        let features = SleepStructureAnalyzer.features(night)
        expect(features.remEpisodes == 1, "3 分钟 REM 碎片应被过滤，实际 \(String(describing: features.remEpisodes))")
        expect(features.remLatencyMinutes == 183, "潜伏期应取过滤后首段（200-17=183），实际 \(String(describing: features.remLatencyMinutes))")
    }

    private static func test深睡前半夜占比() {
        // 睡眠跨度 [17, 240)，中点 128.5：deep [61,105) 44min 在前半、[149,192) 43min 在后半
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(core: (17, 61))
            .deep(61, 105)
            .asleep(core: (105, 149))
            .deep(149, 192)
            .rem(192, 204)
            .asleep(core: (204, 240))
            .build()

        let ratio = SleepStructureAnalyzer.features(night).deepFrontLoadPercent ?? -1
        expect(abs(ratio - 44.0 / 87.0 * 100) < 0.1, "前半夜深睡占比应约 50.6%，实际 \(ratio)")
    }

    private static func test深睡全在后半夜占比为零() {
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(core: (17, 100))
            .rem(100, 120)
            .asleep(core: (120, 140))
            .deep(150, 200)
            .build()

        let ratio = SleepStructureAnalyzer.features(night).deepFrontLoadPercent ?? -1
        expect(ratio == 0, "深睡全在后半夜占比应为 0，实际 \(ratio)")
    }

    private static func test入睡潜伏期按在床到首次入睡计算() {
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(unspecified: (17, 200))
            .build()

        expect(SleepStructureAnalyzer.features(night).sleepOnsetLatencyMinutes == 17, "无阶段但有在床记录时潜伏期应为 17 分钟")
    }

    private static func test无阶段数据时结构特征全部为nil() {
        // iPhone 用户：只有 unspecified 睡着段与在床段，无 deep/rem 分期
        let night = NightSegmentsBuilder()
            .inBed(0, 17)
            .asleep(unspecified: (17, 460))
            .build()

        let features = SleepStructureAnalyzer.features(night)
        expect(features.remEpisodes == nil, "无 REM 数据时 remEpisodes 必须为 nil（不可得 ≠ 0 段）")
        expect(features.remLatencyMinutes == nil, "无 REM 数据时潜伏期必须为 nil")
        expect(features.deepFrontLoadPercent == nil, "无深睡分期时占比必须为 nil")
    }

    private static func test无睡着段返回空特征() {
        let night = SleepStructureAnalyzer.NightSegments(
            asleep: [], core: [], deep: [], rem: [], inBed: [interval(0, 17)]
        )
        let features = SleepStructureAnalyzer.features(night)
        expect(features.remEpisodes == nil && features.deepFrontLoadPercent == nil
                && features.sleepOnsetLatencyMinutes == nil, "无睡着段时全部结构特征应为 nil")
    }
}

/// 测试构造器：链式构建一晚分段。asleep 参数标注来源阶段，全部进 asleep 池。
private struct NightSegmentsBuilder {
    private var asleep: [HealthSleepSampleAggregator.Interval] = []
    private var core: [HealthSleepSampleAggregator.Interval] = []
    private var deep: [HealthSleepSampleAggregator.Interval] = []
    private var rem: [HealthSleepSampleAggregator.Interval] = []
    private var inBed: [HealthSleepSampleAggregator.Interval] = []
    private let base = SleepStructureAnalyzerTests.base

    private func interval(_ start: Double, _ end: Double) -> HealthSleepSampleAggregator.Interval {
        HealthSleepSampleAggregator.Interval(
            start: base.addingTimeInterval(start * 60),
            end: base.addingTimeInterval(end * 60)
        )
    }

    func inBed(_ start: Double, _ end: Double) -> NightSegmentsBuilder {
        var copy = self
        copy.inBed.append(interval(start, end))
        return copy
    }

    func asleep(core startEnd: (Double, Double)) -> NightSegmentsBuilder {
        var copy = self
        let segment = interval(startEnd.0, startEnd.1)
        copy.asleep.append(segment)
        copy.core.append(segment)
        return copy
    }

    func asleep(unspecified startEnd: (Double, Double)) -> NightSegmentsBuilder {
        var copy = self
        copy.asleep.append(interval(startEnd.0, startEnd.1))
        return copy
    }

    func deep(_ start: Double, _ end: Double) -> NightSegmentsBuilder {
        var copy = self
        let segment = interval(start, end)
        copy.asleep.append(segment)
        copy.deep.append(segment)
        return copy
    }

    func rem(_ start: Double, _ end: Double) -> NightSegmentsBuilder {
        var copy = self
        let segment = interval(start, end)
        copy.asleep.append(segment)
        copy.rem.append(segment)
        return copy
    }

    func build() -> SleepStructureAnalyzer.NightSegments {
        SleepStructureAnalyzer.NightSegments(asleep: asleep, core: core, deep: deep, rem: rem, inBed: inBed)
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        SleepStructureAnalyzerTests.main()
    }
}
#endif
