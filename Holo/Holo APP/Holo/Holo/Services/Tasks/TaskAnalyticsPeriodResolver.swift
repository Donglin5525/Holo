//
//  TaskAnalyticsPeriodResolver.swift
//  Holo
//
//  统计周期纯规则解析（方案 §7.2/§7.6/§7.7）：周/月/年/自定义的边界、
//  前后切换、未结束周期的同等已过对比窗口、趋势桶粒度。
//  日历显式 Gregorian + 周一起始 + 设备时区；一切日期推进走日历，禁止 86400 乘法。
//

import Foundation

// MARK: - 周期定义

nonisolated enum TaskAnalyticsPeriod: Equatable, Sendable {
    /// 周（锚定周内任一天；周一起始）
    case week(anchorDay: Date)
    /// 月（锚定月内任一天）
    case month(anchorDay: Date)
    /// 年（锚定年内任一天）
    case year(anchorDay: Date)
    /// 自定义（含首尾自然日）
    case custom(startDay: Date, endDay: Date)

    /// 统计日历：Gregorian、周一为一周之始、首周最少 4 天、设备时区（方案 §7.2）。
    /// 不依赖地区默认周起始日恰好为周一。
    static func makeCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: - 解析结果

/// 已解析的周期边界：start = 开始日 00:00，endExclusive = 结束日次日 00:00
nonisolated struct TaskAnalyticsPeriodBounds: Equatable, Sendable {
    let period: TaskAnalyticsPeriod
    let start: Date
    let endExclusive: Date
    /// 周期尚未结束（endExclusive 在 asOf 之后）
    let isOngoing: Bool
}

/// 未结束周期的同等已过对比窗口（方案 §7.6）
nonisolated struct TaskAnalyticsCompareWindow: Equatable, Sendable {
    let currentStart: Date
    let currentEnd: Date
    let previousStart: Date
    let previousEnd: Date
    /// 上个自然周期更短、比较终点被截到上期结束
    let truncatedToPreviousEnd: Bool
}

// MARK: - 解析器

nonisolated enum TaskAnalyticsPeriodResolver {

    /// 解析周期边界
    static func bounds(
        of period: TaskAnalyticsPeriod,
        asOf: Date,
        calendar: Calendar
    ) -> TaskAnalyticsPeriodBounds {
        let start: Date
        let endExclusive: Date
        switch period {
        case .week(let anchorDay):
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchorDay)
            start = calendar.date(from: comps)!
            endExclusive = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
        case .month(let anchorDay):
            let comps = calendar.dateComponents([.year, .month], from: anchorDay)
            start = calendar.date(from: comps)!
            endExclusive = calendar.date(byAdding: .month, value: 1, to: start)!
        case .year(let anchorDay):
            let comps = calendar.dateComponents([.year], from: anchorDay)
            start = calendar.date(from: comps)!
            endExclusive = calendar.date(byAdding: .year, value: 1, to: start)!
        case .custom(let startDay, let endDay):
            start = calendar.startOfDay(for: startDay)
            endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay))!
        }
        return TaskAnalyticsPeriodBounds(
            period: period,
            start: start,
            endExclusive: endExclusive,
            isOngoing: endExclusive > asOf
        )
    }

    /// 上一个自然周期（自定义 = 紧邻之前的等自然日长度窗口，方案 §7.6-5）
    static func previous(of period: TaskAnalyticsPeriod, calendar: Calendar) -> TaskAnalyticsPeriod {
        switch period {
        case .week(let anchorDay):
            let prevAnchor = calendar.date(byAdding: .weekOfYear, value: -1, to: anchorDay)!
            return .week(anchorDay: prevAnchor)
        case .month(let anchorDay):
            let prevAnchor = calendar.date(byAdding: .month, value: -1, to: anchorDay)!
            return .month(anchorDay: prevAnchor)
        case .year(let anchorDay):
            let prevAnchor = calendar.date(byAdding: .year, value: -1, to: anchorDay)!
            return .year(anchorDay: prevAnchor)
        case .custom(let startDay, let endDay):
            // 含首尾的自然日长度（差值 + 1），等长平移不错位一天
            let dayCount = (calendar.dateComponents([.day], from: calendar.startOfDay(for: startDay), to: calendar.startOfDay(for: endDay)).day ?? 0) + 1
            let prevEnd = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: startDay))!
            let prevStart = calendar.date(byAdding: .day, value: -dayCount, to: calendar.startOfDay(for: startDay))!
            return .custom(startDay: prevStart, endDay: prevEnd)
        }
    }

    /// 下一个自然周期；是否允许进入由 nextAllowed 判定（不能进尚未开始的完整未来周期）
    static func next(of period: TaskAnalyticsPeriod, calendar: Calendar) -> TaskAnalyticsPeriod {
        switch period {
        case .week(let anchorDay):
            return .week(anchorDay: calendar.date(byAdding: .weekOfYear, value: 1, to: anchorDay)!)
        case .month(let anchorDay):
            return .month(anchorDay: calendar.date(byAdding: .month, value: 1, to: anchorDay)!)
        case .year(let anchorDay):
            return .year(anchorDay: calendar.date(byAdding: .year, value: 1, to: anchorDay)!)
        case .custom(let startDay, let endDay):
            let dayCount = (calendar.dateComponents([.day], from: calendar.startOfDay(for: startDay), to: calendar.startOfDay(for: endDay)).day ?? 0) + 1
            let nextStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay))!
            let nextEnd = calendar.date(byAdding: .day, value: dayCount - 1, to: nextStart)!
            return .custom(startDay: nextStart, endDay: nextEnd)
        }
    }

    /// 下一周期是否已开始（周/月/年：next.start < asOf + 1 天内即当前或过去；
    /// 自定义：完整结束晚于今天则禁用，方案 §7.2）
    static func nextAllowed(
        _ period: TaskAnalyticsPeriod,
        asOf: Date,
        calendar: Calendar
    ) -> Bool {
        let nextPeriod = next(of: period, calendar: calendar)
        let nextBounds = bounds(of: nextPeriod, asOf: asOf, calendar: calendar)
        switch period {
        case .week, .month, .year:
            // 不能进入尚未开始的完整未来周期：下一周期起点必须 <= 今天
            return nextBounds.start <= calendar.startOfDay(for: asOf)
        case .custom:
            // 下一等长窗口完整结束晚于今天 → 禁用
            return nextBounds.endExclusive <= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: asOf))!
        }
    }

    /// 同等已过对比窗口（方案 §7.6）：
    /// 已结束周期 = 当前完整 vs 上期完整；未结束 = [start, asOf] vs
    /// 上期起点加相同自然日数 + asOf 的日内时刻（DST/闰年由日历处理）。
    static func compareWindow(
        current: TaskAnalyticsPeriodBounds,
        asOf: Date,
        calendar: Calendar
    ) -> TaskAnalyticsCompareWindow {
        let prevPeriod = previous(of: current.period, calendar: calendar)
        let prevBounds = bounds(of: prevPeriod, asOf: asOf, calendar: calendar)

        let currentEnd: Date
        if current.isOngoing {
            currentEnd = min(asOf, current.endExclusive)
        } else {
            currentEnd = current.endExclusive
        }

        var previousEnd: Date
        var truncated = false
        if current.isOngoing {
            // 从当前起点到 asOf 的完整自然日数 + 日内时刻，平移到上期起点
            let elapsedDays = calendar.dateComponents([.day], from: current.start, to: currentEnd).day ?? 0
            let shifted = calendar.date(byAdding: .day, value: elapsedDays, to: prevBounds.start)!
            var comps = calendar.dateComponents([.hour, .minute, .second], from: currentEnd)
            comps.nanosecond = nil
            previousEnd = calendar.date(from: DateComponents(
                year: calendar.component(.year, from: shifted),
                month: calendar.component(.month, from: shifted),
                day: calendar.component(.day, from: shifted),
                hour: comps.hour ?? 0,
                minute: comps.minute ?? 0,
                second: comps.second ?? 0
            ))!
            // 上个自然周期更短：截到上期结束并如实标记（不假装等长）
            if previousEnd > prevBounds.endExclusive {
                previousEnd = prevBounds.endExclusive
                truncated = true
            }
        } else {
            previousEnd = prevBounds.endExclusive
        }
        return TaskAnalyticsCompareWindow(
            currentStart: current.start,
            currentEnd: currentEnd,
            previousStart: prevBounds.start,
            previousEnd: previousEnd,
            truncatedToPreviousEnd: truncated
        )
    }

    // MARK: - 趋势桶（方案 §7.7）

    enum BucketGranularity: Equatable, Sendable {
        case day
        case month
    }

    struct Bucket: Equatable, Sendable {
        let start: Date
        let endExclusive: Date
        let isFuture: Bool
        /// 今天桶（进行中，显示「截至现在」）
        let isPartialToday: Bool
    }

    /// 桶粒度：周/月按日；年按月；自定义自然日数 ≤31 按日、否则按月
    static func bucketGranularity(
        of bounds: TaskAnalyticsPeriodBounds,
        calendar: Calendar
    ) -> BucketGranularity {
        switch bounds.period {
        case .week, .month:
            return .day
        case .year:
            return .month
        case .custom:
            let days = calendar.dateComponents([.day], from: bounds.start, to: bounds.endExclusive).day ?? 0
            return days <= 31 ? .day : .month
        }
    }

    /// 生成桶序列（月桶只与范围相交，不带入范围外事件；未来桶标记未到来）
    static func buckets(
        of bounds: TaskAnalyticsPeriodBounds,
        asOf: Date,
        calendar: Calendar
    ) -> [Bucket] {
        let granularity = bucketGranularity(of: bounds, calendar: calendar)
        let todayStart = calendar.startOfDay(for: asOf)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        var result: [Bucket] = []
        var cursor = bounds.start
        while cursor < bounds.endExclusive {
            let next: Date
            if granularity == .day {
                next = calendar.date(byAdding: .day, value: 1, to: cursor)!
            } else {
                // 月桶对齐自然月边界：从当前月首 +1 月（首尾桶与范围相交裁剪，§7.7）
                let monthStart = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: cursor)
                )!
                next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            }
            let clampedEnd = min(next, bounds.endExclusive)
            let isFuture = cursor >= tomorrowStart
            // 桶包含 asOf（今天桶/本月桶）→ 进行中，标「截至现在」
            let isPartialToday = !isFuture && cursor <= asOf && asOf < clampedEnd
            result.append(Bucket(
                start: cursor,
                endExclusive: clampedEnd,
                isFuture: isFuture,
                isPartialToday: isPartialToday
            ))
            cursor = next
        }
        return result
    }
}
