//
//  HealthRoutineReviewAnalyzerTests.swift
//  HoloTests
//
//  作息回顾分析器测试：晚睡持续变化、钟点跨午夜换算（23:50↔00:10 差 20 分钟）、
//  无法落入 12 小时弧不给典型值、参考期不足只展示事实、单晚离群不构成变化、
//  窗口截至昨天、冲突/不完整晚排除、前后半段缺样本不判持续。
//  完成条件真源：docs/health/plans/2026-11-17-Holo健康分析实施方案.md 第二步。
//

import Foundation
@testable import Holo

struct HealthRoutineReviewAnalyzerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test晚睡持续变化达到门槛()
        test钟点跨午夜差值为二十分钟()
        test圆形中位数沿午夜连续()
        test无法落入十二小时弧不给典型值()
        test参考期不足只展示事实()
        test单晚离群不构成变化()
        test窗口截至昨天()
        test冲突与不完整晚排除()
        test前半段缺样本不判持续()
        print("HealthRoutineReviewAnalyzerTests passed")
    }

    private static let calendar = Calendar.current

    /// 构造一晚主睡眠：结束日 endDay，入睡时刻 onsetMinute（当地区域分钟），
    /// 时长 7.5 小时。flags 控制可比性。
    private static func night(
        endDay: Date,
        onsetMinute: Int,
        hours: Double = 7.5,
        excludedFromTrends: Bool = false,
        excludedFromClockTrends: Bool = false,
        possiblyIncomplete: Bool = false
    ) -> (endDay: Date, session: HealthNightSession) {
        let day = calendar.startOfDay(for: endDay)
        let onset = calendar.startOfDay(for: day).addingTimeInterval(Double(onsetMinute) * 60)
        let interval = HealthSleepSampleAggregator.Interval(start: onset, end: onset.addingTimeInterval(hours * 3600))
        let session = HealthNightSession(
            kind: .main,
            start: interval.start,
            asleepEnd: interval.end,
            bedStart: nil,
            sessionEnd: interval.end,
            asleepSeconds: hours * 3600,
            timeline: [HealthSleepSegment(stage: .asleepCore, start: interval.start, end: interval.end)],
            stageHours: nil,
            awakeInterruptions: nil,
            sources: [HealthSleepSource(name: "Watch", bundleID: nil, deviceName: nil)],
            stageStatus: .staged,
            candidates: [],
            excludedFromTrends: excludedFromTrends,
            excludedFromClockTrends: excludedFromClockTrends,
            possiblyIncomplete: possiblyIncomplete,
            timezoneID: TimeZone.current.identifier
        )
        return (day, session)
    }

    /// 近 14 晚入睡 00:30、参考 28 晚入睡 23:50、时长恒定 → 入睡 +40 分钟持续变化
    private static func test晚睡持续变化达到门槛() {
        let today = calendar.startOfDay(for: Date())
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(HealthRoutineReviewAnalyzer.referenceDays + HealthRoutineReviewAnalyzer.recentDays)...(-1) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let inRecent = offset >= -HealthRoutineReviewAnalyzer.recentDays
            nights.append(night(endDay: day, onsetMinute: inRecent ? 30 : 1430))
        }
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        let onset = review.changes.first { $0.metric == .onset }
        expect(onset != nil, "入睡推迟 40 分钟应产出变化（40 ≥ 30 门槛）")
        expect(abs(onset!.deltaMinutes - 40) < 1, "变化量应为 +40 分钟，实际 \(onset!.deltaMinutes)")
        expect(onset!.sustained, "前后半段方向一致应为持续变化")
        expect(review.headline?.metric == .onset, "时长无变化时首屏应突出入睡变化")
        expect(review.durationMedianHours != nil && review.onsetSummary.typical != nil, "事实摘要应可用")
        expect(review.recentNightsTotal == 14 && review.referenceNightsTotal == 28, "缺记录不入分母：晚数应为 14/28")
    }

    private static func test钟点跨午夜差值为二十分钟() {
        let delta = HealthRoutineReviewAnalyzer.circularDelta(
            HealthClockMinute(minutes: 10), HealthClockMinute(minutes: 1430)
        )
        expect(abs(delta - 20) < 0.01, "23:50 与 00:10 应相差 20 分钟，实际 \(delta)")
        let back = HealthRoutineReviewAnalyzer.circularDelta(
            HealthClockMinute(minutes: 1430), HealthClockMinute(minutes: 10)
        )
        expect(abs(back + 20) < 0.01, "反向应为 -20 分钟，实际 \(back)")
    }

    private static func test圆形中位数沿午夜连续() {
        // 23:50 与 00:10 的中位数是 00:00（沿 20 分钟弧），不是 11:55
        let median = HealthRoutineReviewAnalyzer.circularMedian(all: [1430, 10])
        expect(median != nil && median!.minutes == 0, "跨午夜两点的中位数应为 00:00，实际 \(String(describing: median))")
        let lateCluster = HealthRoutineReviewAnalyzer.circularMedian(all: [1420, 1430, 1440 + 40])
        expect(lateCluster != nil && lateCluster!.minutes == 1430, "23:40/23:50/00:40 中位数应为 23:50，实际 \(String(describing: lateCluster))")
    }

    private static func test无法落入十二小时弧不给典型值() {
        let scattered = HealthRoutineReviewAnalyzer.circularMedian(all: [23 * 60, 60, 300, 720])
        expect(scattered == nil, "散布超过 12 小时应无典型值，实际 \(String(describing: scattered))")
    }

    /// 参考窗口只有 10 晚（<14）：不给变化，事实照常展示
    private static func test参考期不足只展示事实() {
        let today = calendar.startOfDay(for: Date())
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(10 + 14)...(-1) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let inRecent = offset >= -14
            nights.append(night(endDay: day, onsetMinute: inRecent ? 60 : 1420))
        }
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        expect(review.changes.isEmpty, "参考期 10 晚 < 14 不得产出变化")
        expect(review.durationMedianHours != nil, "近期事实仍展示")
        expect(review.onsetSummary.typical != nil && review.onsetSummary.nights == 14, "典型入睡仍可给")
        expect(review.headline == nil, "无达标变化时首屏不突出变化")
    }

    /// 单晚 11 小时长睡：中位数不动，不得把单晚波动显示成变化
    private static func test单晚离群不构成变化() {
        let today = calendar.startOfDay(for: Date())
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(28 + 14)...(-1) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let inRecent = offset >= -14
            // 全部 7.5 小时，仅最近一晚 11 小时
            let hours = (offset == -1 && inRecent) ? 11.0 : 7.5
            nights.append(night(endDay: day, onsetMinute: 1430, hours: hours))
        }
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        expect(review.changes.filter { $0.metric == .duration }.isEmpty,
               "单晚离群不得构成时长变化（中位数不动），实际 \(review.changes.count) 条")
    }

    /// 今天结束的睡眠记录不进窗口（窗口截至昨天）
    private static func test窗口截至昨天() {
        let today = calendar.startOfDay(for: Date())
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(28 + 14)...(-1) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            nights.append(night(endDay: day, onsetMinute: offset >= -14 ? 30 : 1430))
        }
        // 今天归属的极端晚（入睡 03:00、3 小时）：不得影响窗口
        nights.append(night(endDay: today, onsetMinute: 180, hours: 3))
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        expect(review.recentNightsTotal == 14, "今天的记录不进最近窗口，实际 \(review.recentNightsTotal)")
        let onset = review.changes.first { $0.metric == .onset }
        expect(onset != nil && abs(onset!.deltaMinutes - 40) < 1, "极端今天晚不影响变化值")
    }

    private static func test冲突与不完整晚排除() {
        let today = calendar.startOfDay(for: Date())
        let conflictDay = calendar.date(byAdding: .day, value: -2, to: today)!
        let incompleteDay = calendar.date(byAdding: .day, value: -3, to: today)!
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(28 + 14)...(-1) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            // -2/-3 两个位置换成冲突晚 / 不完整晚（day 与锚点均为 startOfDay，直接比较）
            if day == conflictDay {
                nights.append(night(endDay: day, onsetMinute: 30, excludedFromTrends: true))
            } else if day == incompleteDay {
                nights.append(night(endDay: day, onsetMinute: 30, possiblyIncomplete: true))
            } else {
                nights.append(night(endDay: day, onsetMinute: offset >= -14 ? 30 : 1430))
            }
        }
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        expect(review.recentNightsTotal == 12, "冲突/不完整晚不入分母（14-2=12），实际 \(review.recentNightsTotal)")
        // 12 晚仍 ≥7，变化仍可算
        expect(review.changes.contains { $0.metric == .onset }, "排除后仍有足够覆盖可算变化")
    }

    /// 最近窗口只有后半段有记录：变化可给但不判持续
    private static func test前半段缺样本不判持续() {
        let today = calendar.startOfDay(for: Date())
        var nights: [(endDay: Date, session: HealthNightSession)] = []
        for offset in -(28 + 14)...(-15) {   // 参考期完整 28 天
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            nights.append(night(endDay: day, onsetMinute: 1420))
        }
        for offset in -7...(-1) {            // 近期仅后 7 天有记录
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            nights.append(night(endDay: day, onsetMinute: 60))
        }
        let review = HealthRoutineReviewAnalyzer.analyze(nights: nights, today: today)
        expect(review.recentNightsTotal == 7, "近期应有 7 晚，实际 \(review.recentNightsTotal)")
        let onset = review.changes.first { $0.metric == .onset }
        expect(onset != nil, "7 晚 ≥ 门槛 7 应可给出变化")
        expect(onset!.sustained == false, "前半段 0 晚不得判持续")
    }
}

#if !HOLO_XCTEST_BRIDGE
@main
private struct HoloStandaloneLauncher {
    static func main() {
        HealthRoutineReviewAnalyzerTests.main()
    }
}
#endif
