//
//  HealthSleepSessionSplitterTests.swift
//  HoloTests
//
//  睡眠会话切分器测试：小睡与夜间主睡眠切分、3 小时间隔聚类、尾巴吸收、
//  最长会话为主；以及时间轴卡显示段缝合与整点刻度纯函数。
//

import Foundation
@testable import Holo

struct HealthSleepSessionSplitterTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test小睡与夜间睡眠切成两会话()
        test间隔小于三小时归同一会话()
        test无睡着段返回nil()
        test主睡眠吸收上床与赖床尾巴()
        test最长睡着会话为主睡眠()
        test显示段缝合同阶段细缝()
        test微小清醒段并入底色()
        test刻度每两小时整点()
        test短窗口刻度每小时()
        print("HealthSleepSessionSplitterTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let calendar = Calendar.current

    private static func sample(_ value: Int, _ startMin: Double, _ endMin: Double)
        -> (value: Int, start: Date, end: Date) {
        (value, base.addingTimeInterval(startMin * 60), base.addingTimeInterval(endMin * 60))
    }

    private static func test小睡与夜间睡眠切成两会话() {
        let result = HealthSleepSessionSplitter.split(samples: [
            sample(4, -570, -450),  // 午睡 core（睡前 9.5~7.5 小时）
            sample(0, 0, 17),       // 上床
            sample(5, 17, 240),     // 夜间主睡眠
            sample(4, 240, 420),
            sample(2, 420, 435),    // 末次醒来
            sample(0, 435, 465)     // 赖床
        ])
        expect(result != nil, "有睡着段应产出切分结果")
        let split = result!
        expect(split.napCount == 1, "应有 1 次小睡，实际 \(split.napCount)")
        expect(split.napTotalSeconds == 120 * 60, "小睡时长应为 120 分钟，实际 \(split.napTotalSeconds / 60)")
        expect(split.mainAsleepEnd == base.addingTimeInterval(420 * 60), "主睡着终点应在 420 分钟处")
        // 小睡样本不混入主睡眠；主睡眠最早样本不早于上床链条（60 分钟阈值）
        let starts = split.mainSamples.map { $0.start.timeIntervalSince(base) / 60 }
        expect((starts.min() ?? 0) >= -60, "主睡眠最早样本不应早于上床链条范围，实际 \(String(describing: starts.min()))")
        expect(!split.mainSamples.contains { $0.start < base.addingTimeInterval(-90 * 60) && $0.value == 4 },
               "午睡样本不应混入主睡眠")
    }

    private static func test间隔小于三小时归同一会话() {
        let result = HealthSleepSessionSplitter.split(samples: [
            sample(4, 0, 120),
            sample(4, 270, 400)   // 与上段间隔 2.5 小时
        ])
        expect(result != nil && result!.napCount == 0, "间隔 2.5 小时应为同一会话、无小睡")
        expect(result?.napTotalSeconds == 0, "无小睡时长")
    }

    private static func test无睡着段返回nil() {
        let result = HealthSleepSessionSplitter.split(samples: [
            sample(0, 0, 480)  // 只有在床
        ])
        expect(result == nil, "只有在床无睡着应返回 nil")
    }

    private static func test主睡眠吸收上床与赖床尾巴() {
        let result = HealthSleepSessionSplitter.split(samples: [
            sample(0, -150, -130),  // 距主睡眠起点 130 分钟（≥60）→ 不并入
            sample(0, -60, -30),    // 上床（间隔 30 分钟）→ 吸收
            sample(5, 0, 330),
            sample(2, 330, 430)     // 赖床清醒 100 分钟 → 链条吸收到真实终点
        ])
        expect(result != nil, "有睡着段应产出切分结果")
        let samples = result!.mainSamples
        expect(samples.count == 3, "应保留 上床+睡着+赖床 三段，实际 \(samples.count)")
        expect(samples.first!.start == base.addingTimeInterval(-60 * 60), "最早样本应为链条吸收的上床段")
        expect(samples.last!.end == base.addingTimeInterval(430 * 60), "赖床段应保留到真实终点（不裁剪）")
        expect(result!.mainAsleepEnd == base.addingTimeInterval(330 * 60), "主睡着终点应在 330 分钟处")
    }

    private static func test最长睡着会话为主睡眠() {
        let result = HealthSleepSessionSplitter.split(samples: [
            sample(4, -600, -180),  // 白天 7 小时长睡（倒班形态）
            sample(5, 0, 60)        // 夜间仅 1 小时
        ])
        expect(result != nil && result!.napCount == 1, "短的一段应记为小睡")
        expect(result!.mainSamples.contains { $0.value == 4 }, "睡着最长者（白天长睡）应为主睡眠")
    }

    // MARK: - 时间轴卡显示段（SleepTimelineCard.displaySegments）

    private static func test显示段缝合同阶段细缝() {
        let segments = [
            HealthSleepSegment(stage: .asleepCore, start: base, end: base.addingTimeInterval(600)),
            HealthSleepSegment(stage: .asleepCore, start: base.addingTimeInterval(660), end: base.addingTimeInterval(1200)),
            HealthSleepSegment(stage: .asleepREM, start: base.addingTimeInterval(1260), end: base.addingTimeInterval(1500))
        ]
        let display = SleepTimelineCard.displaySegments(from: segments)
        expect(display.count == 2, "同阶段 1 分钟缝隙应缝合，实际 \(display.count)")
        expect(display[0].duration == 1200, "缝合后应连续到 1200 秒，实际 \(display[0].duration)")
    }

    private static func test微小清醒段并入底色() {
        let segments = [
            HealthSleepSegment(stage: .asleepCore, start: base, end: base.addingTimeInterval(600)),
            HealthSleepSegment(stage: .awake, start: base.addingTimeInterval(600), end: base.addingTimeInterval(630))
        ]
        let display = SleepTimelineCard.displaySegments(from: segments)
        expect(display.count == 1, "30 秒清醒段不应显示，实际 \(display.count)")
    }

    // MARK: - 整点刻度（SleepTimelineCard.tickTimes）

    private static func test刻度每两小时整点() {
        let start = calendar.date(bySettingHour: 23, minute: 20, second: 0, of: base)!
        let end = start.addingTimeInterval(9 * 3600 + 10 * 60)
        let ticks = SleepTimelineCard.tickTimes(windowStart: start, windowEnd: end, calendar: calendar)
        expect(ticks.count == 5, "9 小时窗应有 5 个 2 小时整点刻度，实际 \(ticks.count)")
        expect(ticks.allSatisfy { calendar.component(.minute, from: $0) == 0 }, "刻度应全部落在整点")
        expect(ticks.allSatisfy { $0 > start && $0 < end }, "刻度应严格落在窗口内")
    }

    private static func test短窗口刻度每小时() {
        let start = calendar.date(bySettingHour: 1, minute: 30, second: 0, of: base)!
        let end = start.addingTimeInterval(3 * 3600)
        let ticks = SleepTimelineCard.tickTimes(windowStart: start, windowEnd: end, calendar: calendar)
        expect(ticks.count == 3, "3 小时窗应每整点一个刻度（02/03/04），实际 \(ticks.count)")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        HealthSleepSessionSplitterTests.main()
    }
}
#endif
