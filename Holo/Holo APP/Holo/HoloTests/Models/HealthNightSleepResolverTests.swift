//
//  HealthNightSleepResolverTests.swift
//  HoloTests
//
//  按晚睡眠还原器测试：主睡眠/小睡单列、跨午夜跨中午保时长、缺样本空隙不累加、
//  读取边界标记、双来源裁决（印证采纳/时长并集/偏差待确认）、同源冲突规则、
//  主睡眠并列与孤立短记录、夜醒计数、时区核实。
//  完成条件真源：docs/health/plans/2026-11-17-Holo健康分析实施方案.md 第一步。
//

import Foundation
import HealthKit
@testable import Holo

struct HealthNightSleepResolverTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test主睡眠与午睡单列()
        test跨中午整晚保时长()
        test缺样本空隙不累加时长()
        test跨查询边界标记不完整()
        test双来源印证采纳分期更完整()
        test双来源只时长一致待确认()
        test双来源偏差明显待确认退出趋势()
        test同源分期覆盖笼统记录()
        test同源睡着清醒冲突记未知()
        test同源多分期并盖记未分期()
        test主睡眠并列暂缓对比()
        test孤立短记录不推断主睡眠()
        test夜醒计数与末次醒来不计()
        test时区一致核实与混线索退出钟点()
        print("HealthNightSleepResolverTests passed")
    }

    private static let calendar = Calendar.current
    private static let fallbackTZ = TimeZone.current.identifier

    /// 固定基准日（本地时区 00:00），夜晚 = 前一日 23:00 起
    private static let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    private static var prevDay: Date { calendar.date(byAdding: .day, value: -1, to: day)! }

    private static func at(_ base: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    private static func sample(
        _ value: HKCategoryValueSleepAnalysis,
        from: Date, to: Date,
        source: String = "Watch",
        tz: String? = nil
    ) -> HealthNightSample {
        HealthNightSample(
            value: value.rawValue,
            start: from,
            end: to,
            sourceName: source,
            sourceBundleID: nil,
            deviceName: nil,
            timezoneID: tz
        )
    }

    private static func window(start: Date, end: Date) -> HealthSleepSampleAggregator.Interval {
        HealthSleepSampleAggregator.Interval(start: start, end: end)
    }

    private static func record(
        _ records: [HealthNightSleepRecord], for day: Date
    ) -> HealthNightSleepRecord? {
        records.first { calendar.startOfDay(for: $0.endDate) == day }
    }

    private static func resolve(_ samples: [HealthNightSample], window: HealthSleepSampleAggregator.Interval) -> [HealthNightSleepRecord] {
        HealthNightSleepResolver.resolve(
            samples: samples,
            readWindow: window,
            calendar: calendar,
            fallbackTimezoneID: fallbackTZ
        )
    }

    // MARK: 完成条件①：23:00–次日 07:00 连续 8 小时 + 同结束日 30 分钟午睡

    private static func test主睡眠与午睡单列() {
        let night = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 2)),
            sample(.asleepDeep, from: at(day, 2), to: at(day, 4)),
            sample(.asleepREM, from: at(day, 4), to: at(day, 7))
        ]
        let nap = [sample(.asleepCore, from: at(day, 13), to: at(day, 13, 30))]
        let records = resolve(night + nap, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))

        let result = record(records, for: day)
        expect(result != nil, "结束日应有一条记录")
        let main = result!.mainSession
        expect(main != nil, "应有主睡眠")
        expect(main!.kind == .main, "最长可信睡着段应为主睡眠")
        expect(abs(main!.asleepHours - 8) < 0.01, "主睡眠应为 8 小时，实际 \(main!.asleepHours)")
        expect(main!.start == at(prevDay, 23) && main!.asleepEnd == at(day, 7), "入睡 23:00、记录结束 07:00")
        expect(main!.stageStatus == .staged, "有 core/deep/rem 分期应为 staged")
        // 时间轴与摘要来自同一结果
        expect(main!.stageHours != nil, "应产出分期时长")
        expect(abs(main!.stageHours!.core - 3) < 0.01 && abs(main!.stageHours!.deep - 2) < 0.01 && abs(main!.stageHours!.rem - 3) < 0.01,
               "分期时长 core3/deep2/rem3，实际 \(String(describing: main!.stageHours))")
        let stages = Set(main!.timeline.map(\.stage))
        expect(stages.contains(.asleepCore) && stages.contains(.asleepDeep) && stages.contains(.asleepREM), "时间轴应含三种分期")
        expect(result!.mainAmbiguous == false, "8h 主睡眠与 0.5h 午睡不构成并列")
        // 午睡单列为额外记录
        expect(result!.extraSessions.count == 1, "应有一段额外记录，实际 \(result!.extraSessions.count)")
        let extra = result!.extraSessions[0]
        expect(extra.kind == .nap, "白天 30 分钟段应为小睡，实际 \(extra.kind)")
        expect(abs(extra.asleepHours - 0.5) < 0.01, "午睡应为 0.5 小时")
    }

    // MARK: 完成条件②：跨中午按记录结束日归属、保时长

    private static func test跨中午整晚保时长() {
        let samples = [sample(.asleepCore, from: at(day, 8), to: at(day, 16))]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)
        expect(result != nil && result!.mainSession != nil, "跨中午整晚应有主睡眠")
        expect(abs(result!.mainSession!.asleepHours - 8) < 0.01,
               "08:00–16:00 应保 8 小时（不按中午截断），实际 \(result!.mainSession!.asleepHours)")
        expect(result!.mainSession!.asleepEnd == at(day, 16), "按结束时刻 16:00 归属当日")
    }

    // MARK: 完成条件：缺样本间隔不累加到时长

    private static func test缺样本空隙不累加时长() {
        let samples = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 1)),
            sample(.asleepCore, from: at(day, 3), to: at(day, 7))
        ]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(abs(main.asleepHours - 6) < 0.01, "两段 2h+4h 共 6h，空隙 2h 不累加，实际 \(main.asleepHours)")
        // 时间轴保留空隙：存在 01:00–03:00 的断口
        let sorted = main.timeline.filter { $0.stage != .inBedAwake }.sorted { $0.start < $1.start }
        expect(sorted.count >= 2, "时间轴应保留分段")
        let gapStart = sorted[0].end, gapEnd = sorted[1].start
        expect(gapStart == at(day, 1) && gapEnd == at(day, 3), "空隙应保留在 01:00–03:00")
    }

    // MARK: 完成条件：连接读取边界标记「记录可能不完整」

    private static func test跨查询边界标记不完整() {
        let samples = [sample(.asleepCore, from: at(prevDay, 23), to: at(day, 7))]
        // 读取窗口从 02:00 开始：关心的睡眠段仍连接到读取边界
        let records = resolve(samples, window: window(start: at(day, 2), end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(main.possiblyIncomplete, "睡眠段起点连接读取边界应标记可能不完整")
    }

    // MARK: 完成条件③：双来源冲突——印证 + 分期覆盖更完整者优先、无双算

    private static func test双来源印证采纳分期更完整() {
        let watch = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 3), source: "Watch"),
            sample(.asleepREM, from: at(day, 3), to: at(day, 7), source: "Watch")
        ]
        let autoSleep = [sample(.asleepUnspecified, from: at(prevDay, 23, 15), to: at(day, 6, 45), source: "AutoSleep")]
        let records = resolve(watch + autoSleep, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)!
        expect(result.mainSession != nil, "印证候选应产出主睡眠")
        let main = result.mainSession!
        expect(main.stageStatus == .staged, "分期覆盖更完整的 Watch 候选应被采纳")
        expect(abs(main.asleepHours - 8) < 0.01, "总睡着时长不得双算（8h 而非 14.75h），实际 \(main.asleepHours)")
        expect(main.sources.count == 2, "来源应可核对（两个来源），实际 \(main.sources.map(\.name))")
        expect(result.extraSessions.isEmpty, "同一段睡眠不得既为主睡眠又为额外记录")
    }

    // MARK: 完成条件：只时长一致、分期难以裁决 → 时长并集、分期待确认

    private static func test双来源只时长一致待确认() {
        let watch = [sample(.asleepUnspecified, from: at(prevDay, 23), to: at(day, 7), source: "Watch")]
        let autoSleep = [sample(.asleepUnspecified, from: at(prevDay, 23, 15), to: at(day, 6, 45), source: "AutoSleep")]
        let records = resolve(watch + autoSleep, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(main.stageStatus == .corroboratedPending, "分期难裁决应为待确认，实际 \(main.stageStatus)")
        expect(abs(main.asleepHours - 8) < 0.01, "相互印证的时长（并集）应为 8h，实际 \(main.asleepHours)")
        expect(main.stageHours == nil, "待确认不得产出分期时长")
        expect(!main.excludedFromTrends, "时长经印证不退出趋势")
        expect(main.timeline.allSatisfy { $0.stage == .asleepUnspecified }, "待确认时间轴应为未分期渲染")
    }

    // MARK: 完成条件：时间偏差明显 → 候选 + 待确认 + 退出趋势

    private static func test双来源偏差明显待确认退出趋势() {
        let watch = [sample(.asleepCore, from: at(prevDay, 23), to: at(day, 7), source: "Watch")]
        let autoSleep = [sample(.asleepCore, from: at(day, 1), to: at(day, 7), source: "AutoSleep")]
        let records = resolve(watch + autoSleep, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)!
        expect(result.mainSession == nil, "无法裁决的晚不得给出主睡眠结论")
        let pending = result.extraSessions
        expect(pending.count == 1 && pending[0].stageStatus == .conflicting, "应产出一条待确认记录")
        let shell = pending[0]
        expect(shell.candidates.count == 2, "应展示两个来源的候选记录，实际 \(shell.candidates.count)")
        expect(shell.candidates.contains { $0.source.name == "AutoSleep" } && shell.candidates.contains { $0.source.name == "Watch" }, "候选应带来源")
        expect(shell.excludedFromTrends, "来源冲突应退出趋势")
        expect(shell.timeline.isEmpty, "来源冲突不合成时间轴")
        expect(shell.stageHours == nil, "来源冲突不产出分期")
    }

    // MARK: 规则表：有明确分期的睡着段覆盖笼统的睡着记录

    private static func test同源分期覆盖笼统记录() {
        let samples = [
            sample(.asleepUnspecified, from: at(prevDay, 23), to: at(day, 7)),
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 7))
        ]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(main.stageStatus == .staged, "分期应覆盖笼统记录")
        expect(abs(main.stageHours!.core - 8) < 0.01, "分期时长应为 8h core")
        expect(main.timeline.allSatisfy { $0.stage == .asleepCore }, "时间轴应为 core 而非未分期")
    }

    // MARK: 规则表：睡着和清醒相互冲突的区间标为未知

    private static func test同源睡着清醒冲突记未知() {
        let samples = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 2)),
            sample(.awake, from: at(day, 0), to: at(day, 1))
        ]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(abs(main.asleepHours - 2) < 0.01, "冲突小时区不计入睡着时长（3h 样本 - 1h 冲突 = 2h），实际 \(main.asleepHours)")
        expect(main.timeline.contains { $0.stage == .conflict }, "时间轴应含未知（冲突）段")
        let conflict = main.timeline.first { $0.stage == .conflict }!
        expect(conflict.start == at(day, 0) && conflict.end == at(day, 1), "冲突段应为 00:00–01:00")
    }

    // MARK: 规则表：细分冲突记为未分期

    private static func test同源多分期并盖记未分期() {
        let samples = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 7)),
            sample(.asleepDeep, from: at(prevDay, 23), to: at(day, 7))
        ]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(main.stageStatus == .unstaged, "core 与 deep 并盖应为未分期，实际 \(main.stageStatus)")
        expect(main.stageHours == nil, "未分期不产出分期时长")
        expect(main.timeline.allSatisfy { $0.stage == .asleepUnspecified }, "时间轴应为未分期")
        expect(abs(main.asleepHours - 8) < 0.01, "时长保留")
    }

    // MARK: 规则表：两段均 ≥2 小时且相差 <60 分钟 → 暂缓主睡眠对比

    private static func test主睡眠并列暂缓对比() {
        let samples = [
            sample(.asleepCore, from: at(day, 0), to: at(day, 4)),
            sample(.asleepCore, from: at(day, 8), to: at(day, 12))
        ]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)!
        expect(result.mainAmbiguous, "两段各 4 小时应标记主睡眠并列")
        expect(result.mainSession == nil, "并列时不得给出主睡眠")
        expect(result.extraSessions.count == 2, "两段都应展示")
        expect(result.extraSessions.allSatisfy { $0.kind == .otherSleep }, "并列段展示为两个睡眠段")
    }

    // MARK: 规则表：孤立的短记录不推断主睡眠

    private static func test孤立短记录不推断主睡眠() {
        let samples = [sample(.asleepUnspecified, from: at(day, 14), to: at(day, 14, 20))]
        let records = resolve(samples, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)!
        expect(result.mainSession == nil && !result.mainAmbiguous, "20 分钟孤立短记录不推断主睡眠")
        expect(result.extraSessions.count == 1 && result.extraSessions[0].kind == .record, "应展示为睡眠记录")
    }

    // MARK: 夜醒计数沿用 ≥2 分钟口径；末次醒来不计

    private static func test夜醒计数与末次醒来不计() {
        let withWake = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 3)),
            sample(.awake, from: at(day, 3), to: at(day, 3, 10)),
            sample(.asleepCore, from: at(day, 3, 10), to: at(day, 7))
        ]
        let records = resolve(withWake, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main = record(records, for: day)!.mainSession!
        expect(main.awakeInterruptions == 1, "睡着区间内 10 分钟清醒应为 1 次夜醒，实际 \(String(describing: main.awakeInterruptions))")
        // 末段睡着结束后的清醒是「末次醒来（起床）」，不计夜醒
        let tailAwake = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 6)),
            sample(.awake, from: at(day, 6), to: at(day, 6, 15))
        ]
        let records2 = resolve(tailAwake, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main2 = record(records2, for: day)!.mainSession!
        expect(main2.awakeInterruptions == 0, "末次醒来不计夜醒，实际 \(String(describing: main2.awakeInterruptions))")
    }

    // MARK: 规则表：时区一致可核实；线索不一致退出钟点比较、保留时长

    private static func test时区一致核实与混线索退出钟点() {
        let consistent = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 3), tz: "Asia/Shanghai"),
            sample(.asleepREM, from: at(day, 3), to: at(day, 7), tz: "Asia/Shanghai")
        ]
        let records = resolve(consistent, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let result = record(records, for: day)!
        expect(result.mainSession!.timezoneID == "Asia/Shanghai", "一致时区线索应保留")
        expect(result.timezoneVerified, "一致时区应核实")
        expect(!result.mainSession!.excludedFromClockTrends, "核实的时区参与钟点比较")

        let mixed = [
            sample(.asleepCore, from: at(prevDay, 23), to: at(day, 3), tz: "Asia/Shanghai"),
            sample(.asleepREM, from: at(day, 3), to: at(day, 7), tz: "Asia/Tokyo")
        ]
        let records2 = resolve(mixed, window: window(start: prevDay, end: calendar.date(byAdding: .day, value: 1, to: day)!))
        let main2 = record(records2, for: day)!.mainSession!
        expect(main2.timezoneID == nil, "线索不一致不采信任何时区")
        expect(main2.excludedFromClockTrends, "线索不一致应退出钟点比较")
        expect(!main2.excludedFromTrends, "时长保留在趋势中")
        expect(abs(main2.asleepHours - 8) < 0.01, "时区问题不影响时长")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        HealthNightSleepResolverTests.main()
    }
}
#endif

#if HOLO_XCTEST_BRIDGE
import XCTest
// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件、只在测试工程编译时生效；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}
#endif
