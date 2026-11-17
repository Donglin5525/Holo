//
//  HealthRoutineReviewAnalyzer.swift
//  Holo
//
//  作息回顾分析器（健康分析方案 2026-11-17 第二步）：
//  用按晚还原的主睡眠结果计算「最近 14 天 vs 此前 28 天」的作息变化。
//
//  口径：
//  - 固定窗口：最近 14 个完整归属日截至昨天，参考窗口为再往前不重叠的 28 天；
//    今天同步的记录不进窗口（进入完整归属日后才纳入）；
//  - 覆盖门槛：最近窗口 ≥7 晚、参考窗口 ≥14 晚，缺记录不入分母；
//  - 变化 = 两段中位数之差；钟点沿午夜连续换算（23:50 与 00:10 相差 20 分钟），
//    两段钟点无法落入同一个 <12 小时弧时只展示时间点、不给典型值与变化；
//  - 展示门槛 = max(30 分钟, 参考期四分位距一半)；持续变化需近 14 天前后
//    各 7 天均有 ≥3 个可比点且方向一致；
//  - 日型：两期周末占比相差 ≤20 个百分点直接合并比较，否则只取两期均有
//    足够覆盖的同一日型；都没有则只展示近期事实。
//  窗口与门槛为试用默认值，集中配置，待真实记录校准。
//  纯函数，供 Repository / 页面与测试共用；不访问健康数据库。
//

import Foundation

// MARK: - 结果模型

/// 当地钟点（分钟，0..<1440），按展示时区
struct HealthClockMinute: Equatable, Sendable {
    let minutes: Int

    init(minutes: Int) {
        self.minutes = ((minutes % 1440) + 1440) % 1440
    }
}

/// 归属日区间（含首尾，startOfDay）
struct HealthDateRange: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// 作息回顾结果（同一份结构化结果供首页、详情与「今日」消费）
struct HealthRoutineReview: Equatable, Sendable {
    enum Metric: String, Sendable, CaseIterable {
        case duration   // 主睡眠时长
        case onset      // 入睡时间
        case recordEnd  // 记录结束时间
    }

    /// 钟点指标摘要：typical = nil 表示无法给出单一典型时间
    struct ClockSummary: Equatable, Sendable {
        let typical: HealthClockMinute?
        let nights: Int
    }

    /// 达到展示门槛的一处变化
    struct MetricChange: Equatable, Sendable {
        let metric: Metric
        /// 变化量（分钟；正 = 变晚/变长，负 = 变早/变短）
        let deltaMinutes: Double
        /// 近期中位数（时长=小时，钟点=分钟）
        let recentMedian: Double
        /// 参考期中位数
        let referenceMedian: Double
        let recentNights: Int
        let referenceNights: Int
        /// 前后 7 天方向一致（持续变化）
        let sustained: Bool
        /// 参与比较的归属日
        let validNights: [Date]
    }

    /// 锚定「今天」（窗口截至昨天）
    let today: Date
    /// 最近 14 个完整归属日（含首尾，startOfDay）
    let recentRange: HealthDateRange
    /// 参考期 28 天（与最近窗口不重叠）
    let referenceRange: HealthDateRange
    /// 窗口内主睡眠晚数（可比性过滤前）
    let recentNightsTotal: Int
    let referenceNightsTotal: Int
    /// 近期事实：主睡眠时长中位数（小时）
    let durationMedianHours: Double?
    /// 近期事实：入睡/记录结束典型钟点
    let onsetSummary: ClockSummary
    let recordEndSummary: ClockSummary
    /// 所有达到展示门槛的变化（时长 → 入睡 → 记录结束 优先级排序）
    let changes: [MetricChange]
    /// 首屏只突出一条；nil = 无达标变化（用事实摘要）
    var headline: MetricChange? { changes.first }
    /// 与 headline 同一批有效晚、也达标的第二指标（可合并成一句解释）
    var headlineCompanion: MetricChange?
}

// MARK: - 分析器

/// 单晚指标点（分析器内部用）
private struct HealthRoutineNightPoint {
    let day: Date
    let durationHours: Double
    /// -1 = 钟点不可比（时区线索不一致），不参与钟点指标
    let onsetMinutes: Int
    let endMinutes: Int
    let isWeekend: Bool
}

nonisolated enum HealthRoutineReviewAnalyzer {

    // 试用默认值（方案 §第二步；集中配置，真实记录校准后调整）
    static let recentDays = 14
    static let referenceDays = 28
    static let recentMinimumNights = 7
    static let referenceMinimumNights = 14
    /// 变化门槛下限（分钟）
    static let changeFloorMinutes: Double = 30
    /// 两期周末样本占比相差上限（0-1）
    static let weekendShareTolerance: Double = 0.20
    /// 持续变化：前后半段各需最少可比点
    static let persistenceHalfMinimum = 3
    /// 钟点可给典型值的最大弧长（分钟）
    static let clockArcMaximum: Double = 720

    /// 输入：归属日 + 该晚主睡眠（调用方只传有主睡眠的晚）。
    /// 今天 = 展示锚点（窗口截至昨天）；会话时区线索缺失时钟点按本地时区折算。
    static func analyze(
        nights: [(endDay: Date, session: HealthNightSession)],
        today: Date,
        calendar: Calendar = .current
    ) -> HealthRoutineReview {
        let calendar = calendar
        let todayStart = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let recentStart = calendar.date(byAdding: .day, value: -(recentDays - 1), to: yesterday)!
        let referenceEnd = calendar.date(byAdding: .day, value: -1, to: recentStart)!
        let referenceStart = calendar.date(byAdding: .day, value: -(referenceDays - 1), to: referenceEnd)!

        func inRecent(_ day: Date) -> Bool { day >= recentStart && day <= yesterday }
        func inReference(_ day: Date) -> Bool { day >= referenceStart && day <= referenceEnd }

        // 可比性过滤：来源冲突 / 记录可能不完整的晚不参与比较（试用口径）
        func comparable(_ session: HealthNightSession, clock: Bool) -> Bool {
            !session.excludedFromTrends && !session.possiblyIncomplete
                && (!clock || !session.excludedFromClockTrends)
        }

        let normalized = nights.map { (calendar.startOfDay(for: $0.endDay), $0.session) }

        // 指标样本：时长（全部可比晚）；钟点（另需时区可比）
        var recentPoints: [HealthRoutineNightPoint] = []
        var referencePoints: [HealthRoutineNightPoint] = []
        for (day, session) in normalized where inRecent(day) || inReference(day) {
            guard comparable(session, clock: false) else { continue }
            let clockOK = comparable(session, clock: true)
            let tz = TimeZone(identifier: session.timezoneID ?? TimeZone.current.identifier) ?? .current
            var tzCalendar = calendar
            tzCalendar.timeZone = tz
            func minuteOfDay(_ date: Date) -> Int {
                let hour = tzCalendar.component(.hour, from: date)
                let minute = tzCalendar.component(.minute, from: date)
                return hour * 60 + minute
            }
            let point = HealthRoutineNightPoint(
                day: day,
                durationHours: session.asleepHours,
                onsetMinutes: clockOK ? minuteOfDay(session.start) : -1,
                endMinutes: clockOK ? minuteOfDay(session.asleepEnd) : -1,
                isWeekend: isWeekendDay(day, calendar: calendar)
            )
            if inRecent(day) { recentPoints.append(point) } else { referencePoints.append(point) }
        }

        // 近期事实（不做门槛判定，有什么展示什么）
        let recentDurations = recentPoints.map(\.durationHours)
        let durationMedian = median(recentDurations)
        let onsetSummary = clockSummary(recentPoints.compactMap { $0.onsetMinutes >= 0 ? $0.onsetMinutes : nil })
        let endSummary = clockSummary(recentPoints.compactMap { $0.endMinutes >= 0 ? $0.endMinutes : nil })

        // 变化计算（按时长 → 入睡 → 记录结束 优先级）
        var changes: [HealthRoutineReview.MetricChange] = []
        if let durationChange = change(
            metric: .duration,
            recent: recentPoints,
            reference: referencePoints,
            value: { $0.durationHours },   // 时长指标用小时；分钟换算在 delta/门槛处统一做
            clock: false,
            calendar: calendar
        ) {
            changes.append(durationChange)
        }
        for (metric, keyPath) in [(HealthRoutineReview.Metric.onset, \HealthRoutineNightPoint.onsetMinutes),
                                  (HealthRoutineReview.Metric.recordEnd, \HealthRoutineNightPoint.endMinutes)] {
            if let clockChange = change(
                metric: metric,
                recent: recentPoints,
                reference: referencePoints,
                value: { $0[keyPath: keyPath] >= 0 ? Double($0[keyPath: keyPath]) : nil },
                clock: true,
                calendar: calendar
            ) {
                changes.append(clockChange)
            }
        }

        // 首屏只突出一条；同一批有效晚的第二个达标指标可合并成一句
        var companion: HealthRoutineReview.MetricChange?
        if let headline = changes.first {
            companion = changes.dropFirst().first {
                $0.metric != headline.metric && Set($0.validNights.map { $0.timeIntervalSince1970 }) == Set(headline.validNights.map { $0.timeIntervalSince1970 })
            }
        }

        return HealthRoutineReview(
            today: todayStart,
            recentRange: HealthDateRange(start: recentStart, end: yesterday),
            referenceRange: HealthDateRange(start: referenceStart, end: referenceEnd),
            recentNightsTotal: recentPoints.count,
            referenceNightsTotal: referencePoints.count,
            durationMedianHours: durationMedian,
            onsetSummary: onsetSummary,
            recordEndSummary: endSummary,
            changes: changes,
            headlineCompanion: companion
        )
    }

    // MARK: - 私有计算

    private static func isWeekendDay(_ day: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        return weekday == 1 || weekday == 7
    }

    /// 线性中位数（偶数取中间均值）
    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// 钟点摘要：整组能落入 <12 小时弧才给典型值
    private static func clockSummary(_ minutes: [Int]) -> HealthRoutineReview.ClockSummary {
        guard !minutes.isEmpty else { return .init(typical: nil, nights: 0) }
        let typical = circularMedian(all: minutes)
        return .init(typical: typical, nights: minutes.count)
    }

    /// 圆形中位数：钟点沿午夜连续换算。
    /// 先找最大空隙，其余数据落成 <12 小时弧才可线性取中位。
    static func circularMedian(all minutes: [Int]) -> HealthClockMinute? {
        guard !minutes.isEmpty else { return nil }
        let sorted = minutes.map { (($0 % 1440) + 1440) % 1440 }.sorted()
        guard sorted.count > 1 else { return HealthClockMinute(minutes: sorted[0]) }
        var maxGap = 1440 - sorted.last! + sorted.first!
        var gapEndIndex = 0   // 最大空隙结束处的下标（弧从这里开始）
        for i in 1..<sorted.count where sorted[i] - sorted[i - 1] > maxGap {
            maxGap = sorted[i] - sorted[i - 1]
            gapEndIndex = i
        }
        let arc = Double(1440 - maxGap)
        guard arc <= clockArcMaximum else { return nil }
        // 沿弧展开：从空隙后第一个值起，跨过 0 点补 1440
        let unwrapped = sorted[gapEndIndex...].map { Double($0) }
            + sorted[..<gapEndIndex].map { Double($0 + 1440) }
        guard let medianValue = median(unwrapped) else { return nil }
        return HealthClockMinute(minutes: Int(medianValue.rounded()))
    }

    /// 圆形差（分钟），沿午夜连续：23:50 与 00:10 相差 20
    static func circularDelta(_ recent: HealthClockMinute, _ reference: HealthClockMinute) -> Double {
        let raw = Double(recent.minutes - reference.minutes)
        var delta = raw.truncatingRemainder(dividingBy: 1440)
        if delta > 720 { delta -= 1440 }
        if delta < -720 { delta += 1440 }
        return delta
    }

    /// 四分位距（线性值；钟点用已展开的弧内值）
    private static func interquartileRange(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard sorted.count >= 4 else { return 0 }
        func quantile(_ p: Double) -> Double {
            let position = p * Double(sorted.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, sorted.count - 1)
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
        return quantile(0.75) - quantile(0.25)
    }

    /// 单指标变化计算：日型门槛 → 覆盖门槛 → 中位数与门槛 → 持续性
    private static func change(
        metric: HealthRoutineReview.Metric,
        recent: [HealthRoutineNightPoint],
        reference: [HealthRoutineNightPoint],
        value: (HealthRoutineNightPoint) -> Double?,
        clock: Bool,
        calendar: Calendar
    ) -> HealthRoutineReview.MetricChange? {
        // 日型构成：占比接近直接合并，否则取两期覆盖都够的同一日型
        func weekendShare(_ points: [HealthRoutineNightPoint]) -> Double {
            points.isEmpty ? 0 : Double(points.filter(\.isWeekend).count) / Double(points.count)
        }
        var recentSet = recent.compactMap { point -> (Date, Double)? in value(point).map { (point.day, $0) } }
        var referenceSet = reference.compactMap { point -> (Date, Double)? in value(point).map { (point.day, $0) } }

        if abs(weekendShare(recent) - weekendShare(reference)) > weekendShareTolerance {
            let options: [Bool] = [false, true]   // 优先工作日（样本通常更多）
            var matched = false
            for weekend in options {
                let recentSub = recent.filter { $0.isWeekend == weekend }.compactMap { point -> (Date, Double)? in value(point).map { (point.day, $0) } }
                let referenceSub = reference.filter { $0.isWeekend == weekend }.compactMap { point -> (Date, Double)? in value(point).map { (point.day, $0) } }
                if recentSub.count >= recentMinimumNights && referenceSub.count >= referenceMinimumNights {
                    recentSet = recentSub
                    referenceSet = referenceSub
                    matched = true
                    break
                }
            }
            guard matched else { return nil }   // 无足够对照：仍展示近期事实（由调用方渲染）
        }

        guard recentSet.count >= recentMinimumNights, referenceSet.count >= referenceMinimumNights else {
            return nil
        }

        // 钟点指标：两段各自需可落入同一弧（典型值可得），变化沿午夜连续换算
        var recentMedian = median(recentSet.map(\.1))
        var referenceMedian = median(referenceSet.map(\.1))
        if clock {
            guard let recentTypical = circularMedian(all: recentSet.map { Int($0.1.rounded()) }),
                  let referenceTypical = circularMedian(all: referenceSet.map { Int($0.1.rounded()) }) else { return nil }
            recentMedian = Double(recentTypical.minutes)
            referenceMedian = Double(referenceTypical.minutes)
        }
        guard let recentMedian, let referenceMedian else { return nil }

        let deltaMinutes: Double
        let threshold: Double
        if clock {
            deltaMinutes = circularDelta(
                HealthClockMinute(minutes: Int(recentMedian)),
                HealthClockMinute(minutes: Int(referenceMedian))
            )
            threshold = max(changeFloorMinutes, interquartileRange(referenceSet.map(\.1)) / 2)
        } else {
            deltaMinutes = (recentMedian - referenceMedian) * 60   // 小时 → 分钟
            threshold = max(changeFloorMinutes, interquartileRange(referenceSet.map(\.1)) * 60 / 2)
        }
        guard abs(deltaMinutes) >= threshold else { return nil }

        // 持续性：近 14 天前后各 7 天均有 ≥3 个可比点且方向一致
        let sustained = persistenceCheck(recentSet: recentSet, referenceMedian: referenceMedian, clock: clock, calendar: calendar)

        return HealthRoutineReview.MetricChange(
            metric: metric,
            deltaMinutes: deltaMinutes,
            recentMedian: recentMedian,
            referenceMedian: referenceMedian,
            recentNights: recentSet.count,
            referenceNights: referenceSet.count,
            sustained: sustained,
            validNights: recentSet.map(\.0).sorted()
        )
    }

    /// 前后半段（按归属日各 7 天）中位数相对参考期方向一致。
    /// 钟点指标按圆形差判定（跨午夜不判反方向）；半段无法落弧时不判持续。
    private static func persistenceCheck(
        recentSet: [(Date, Double)],
        referenceMedian: Double,
        clock: Bool,
        calendar: Calendar
    ) -> Bool {
        let days = recentSet.map(\.0).sorted()
        guard let newest = days.last else { return false }
        let midpoint = calendar.date(byAdding: .day, value: -(recentDays / 2), to: calendar.date(byAdding: .day, value: 1, to: newest)!)!
        let olderHalf = recentSet.filter { $0.0 < midpoint }
        let newerHalf = recentSet.filter { $0.0 >= midpoint }
        guard olderHalf.count >= persistenceHalfMinimum, newerHalf.count >= persistenceHalfMinimum else {
            return false
        }
        func halfDelta(_ half: [(Date, Double)]) -> Double? {
            if clock {
                guard let typical = circularMedian(all: half.map { Int($0.1.rounded()) }) else { return nil }
                return circularDelta(typical, HealthClockMinute(minutes: Int(referenceMedian.rounded())))
            }
            guard let medianValue = median(half.map(\.1)) else { return nil }
            return medianValue - referenceMedian
        }
        guard let olderDelta = halfDelta(olderHalf),
              let newerDelta = halfDelta(newerHalf) else { return false }
        return olderDelta * newerDelta > 0   // 同方向（都不为零）
    }
}
