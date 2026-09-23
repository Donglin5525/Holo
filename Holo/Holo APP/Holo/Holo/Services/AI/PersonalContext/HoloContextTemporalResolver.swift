//
//  HoloContextTemporalResolver.swift
//  Holo
//
//  通用个人情境的时间计算（实施方案 §4.3/§7）。
//
//  - 所有精确日期计算使用注入的 Calendar/timezone；测试覆盖月末、跨年、时区。
//  - 模糊时间（月初/上个月）保留原文表达，不得转成固定日期。
//  - 周期标识（periodKey）：月=yyyy-MM，周=ISO 周 yyyy-'W'ww。
//  - 本月完成只更新实例；本次延期是 exception；推荐某时段不等于拥有日程。
//
//  纯逻辑，可 standalone 编译。
//

import Foundation

nonisolated enum HoloContextTemporalResolver {
    // MARK: - 周期标识

    /// 月度周期键：yyyy-MM（按注入日历的时区）。
    static func monthPeriodKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// 周度周期键：ISO 周 yyyy-Www。
    static func weekPeriodKey(for date: Date, calendar: Calendar) -> String {
        var iso = calendar
        // ISO 周以周一为一周起点。
        iso.firstWeekday = 2
        let components = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(
            format: "%04d-W%02d",
            components.yearForWeekOfYear ?? 0,
            components.weekOfYear ?? 0
        )
    }

    /// 周期实例的周期键（按 recurrence 频率）。
    static func periodKey(
        for recurrence: HoloContextRecurrenceV1,
        at date: Date,
        calendar: Calendar
    ) -> String {
        switch recurrence.frequency {
        case .daily:
            return ISO8601DateFormatter().string(from: date)
        case .weekly:
            return weekPeriodKey(for: date, calendar: calendar)
        case .monthly, .yearly:
            return monthPeriodKey(for: date, calendar: calendar)
        }
    }

    // MARK: - 时间重叠

    /// 情境时间是否与参考区间重叠（职责/规则的时间份额判定，§7.1）。
    /// ongoing 恒重叠；event 看区间；recurring 必须有具体发生日期落进区间
    /// （R10 修复：不再「活跃即恒真」）；conditional 无明确时间锚时保守视为可能重叠。
    static func overlaps(
        temporal: HoloContextTemporalV1,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        switch temporal.kind {
        case .ongoing:
            // 无明确终点的持续状态：只要未在区间开始前结束。
            if let validTo = temporal.validTo {
                return validTo >= rangeStart
            }
            return true
        case .event:
            guard let from = temporal.validFrom else { return true }
            let to = temporal.validTo ?? from
            return from <= rangeEnd && to >= rangeStart
        case .recurring:
            if let validTo = temporal.validTo, validTo < rangeStart {
                return false
            }
            if let validFrom = temporal.validFrom, validFrom > rangeEnd {
                return false
            }
            // 周期规则：锚点齐全时必须算出区间内的真实发生日期（R10）。
            guard let recurrence = temporal.recurrence else {
                // 无结构化锚点（模糊周期表达）：保留原文语义，保守视为可能重叠。
                return true
            }
            let searchStart = max(temporal.validFrom ?? rangeStart, rangeStart)
            guard let next = nextOccurrence(
                of: recurrence, after: searchStart.addingTimeInterval(-1), calendar: calendar
            ) else {
                // 锚点不全（如 weekly 缺 weekday）：无法计算发生日期，保守处理。
                return true
            }
            return next.date <= rangeEnd
        case .conditional:
            // 条件性：无明确时间锚时保守视为可能相关。
            return true
        }
    }

    /// 规则在参考时点是否仍可参考（失效/已结束规则不进建议背景）。
    /// 只回答「是否已结束」；尚未开始（validFrom 在未来）的未来事件/责任
    /// 不算失效——与区间的重叠由 overlaps 判定（R3：未来预约不得被错杀）。
    static func isActive(temporal: HoloContextTemporalV1, at now: Date) -> Bool {
        if let validTo = temporal.validTo, validTo < now {
            return false
        }
        return true
    }

    // MARK: - 精确周期计算

    struct ResolvedOccurrence: Equatable, Sendable {
        var periodKey: String
        var date: Date
    }

    /// 明确周期的下一次发生（从 from 起算，含 from 当期）。
    /// 仅处理结构化锚点齐全的 recurrence；未知锚点返回 nil（模糊时间保留原文，不伪造）。
    static func nextOccurrence(
        of recurrence: HoloContextRecurrenceV1,
        after reference: Date,
        calendar: Calendar
    ) -> ResolvedOccurrence? {
        let interval = max(recurrence.interval, 1)
        switch recurrence.frequency {
        case .daily:
            let next = calendar.date(
                byAdding: .day,
                value: interval,
                to: calendar.startOfDay(for: reference)
            ) ?? reference
            return ResolvedOccurrence(periodKey: ISO8601DateFormatter().string(from: next), date: next)
        case .weekly:
            guard let weekday = recurrence.weekday, (1...7).contains(weekday) else { return nil }
            var next = calendar.startOfDay(for: reference)
            let currentWeekday = calendar.component(.weekday, from: next)
            var delta = (weekday - currentWeekday + 7) % 7
            if delta == 0 {
                delta = 7 * interval
            }
            next = calendar.date(byAdding: .day, value: delta, to: next) ?? next
            return ResolvedOccurrence(periodKey: weekPeriodKey(for: next, calendar: calendar), date: next)
        case .monthly:
            guard let dayOfMonth = recurrence.dayOfMonth, (1...31).contains(dayOfMonth) else { return nil }
            var components = calendar.dateComponents([.year, .month], from: reference)
            var candidate = calendar.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: min(dayOfMonth, daysInMonth(year: components.year ?? 0, month: components.month ?? 0, calendar: calendar))
            ))
            if let date = candidate, date < calendar.startOfDay(for: reference) {
                components.month? += interval
                candidate = calendar.date(from: DateComponents(
                    year: components.year,
                    month: components.month,
                    day: min(dayOfMonth, daysInMonth(year: components.year ?? 0, month: components.month ?? 0, calendar: calendar))
                ))
            }
            guard let date = candidate else { return nil }
            return ResolvedOccurrence(periodKey: monthPeriodKey(for: date, calendar: calendar), date: date)
        case .yearly:
            guard let month = recurrence.month, (1...12).contains(month),
                  let dayOfMonth = recurrence.dayOfMonth else { return nil }
            var year = calendar.component(.year, from: reference)
            var candidate = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
            if let date = candidate, date < calendar.startOfDay(for: reference) {
                year += interval
                candidate = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
            }
            guard let date = candidate else { return nil }
            return ResolvedOccurrence(periodKey: monthPeriodKey(for: date, calendar: calendar), date: date)
        }
    }

    /// 当月天数（月末钳制：1/31 在 2 月取到 28/29，不溢出到 3 月）。
    static func daysInMonth(year: Int, month: Int, calendar: Calendar) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month)) ?? Date()) else {
            return 30
        }
        return range.count
    }

    // MARK: - 实例状态

    /// 本周期实例状态判定：有完成证据→done；例外记录→exception；否则 unknown（不能默认 pending）。
    static func occurrenceStatus(
        occurrences: [HoloContextOccurrence],
        contextID: String,
        periodKey: String
    ) -> HoloContextOccurrence.Status {
        occurrences.first { $0.contextID == contextID && $0.periodKey == periodKey }?.status ?? .unknown
    }
}
