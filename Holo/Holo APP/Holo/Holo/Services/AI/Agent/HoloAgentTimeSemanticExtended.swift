//
//  HoloAgentTimeSemanticExtended.swift
//  Holo
//
//  Agent 成熟度演进 P0-B — 时间语义解析扩展
//
//  在现有 HoloAgentTimeSemanticResolver 基础上扩展：
//    1. 季度（Q1-Q4 / 一季度~四季度）
//    2. 年初至今（今年以来 / 今年到现在）
//    3. 工作日/周末区分
//    4. 解析结果带 assumption / completeness / comparisonAlignment，供回答披露和 Verifier 使用
//
//  不替换原有 Resolver；新解析能力作为独立函数提供，由 Runtime 按需调用。
//

import Foundation

// MARK: - 扩展的时间语义 Kind

nonisolated enum HoloAgentExtendedTimeKind: String, Equatable, Sendable {
    case quarter             // 季度（Q1-Q4）
    case yearToDate          // 年初至今
    case weekday             // 工作日范围
    case weekend             // 周末范围
    case monthToDate         // 当前月至今（区别于完整自然月）
    case lastFullMonth       // 上一完整自然月
}

// MARK: - 解析结果的元数据

/// 时间解析的附加元数据，用于回答披露和 Verifier 判定。
nonisolated struct HoloAgentTimeAssumption: Equatable, Sendable {
    /// 解析所用的产品默认假设（如"最近=最近30天"）。
    var assumption: String
    /// 数据完整度：complete=完整自然周期 / partial=周期未结束 / projected=需推算
    var completeness: HoloAgentTimeCompleteness
    /// 对比周期对齐情况：aligned=自然对齐 / approximate=近似对齐 / unaligned=不可比
    var comparisonAlignment: HoloAgentComparisonAlignment?
    /// 是否为不完整周期（如当前月只过了15天）
    var isIncompletePeriod: Bool
}

nonisolated enum HoloAgentTimeCompleteness: String, Equatable, Sendable {
    case complete    // 完整自然周期（如上月、去年）
    case partial     // 周期未结束（如本月，今天才15号）
    case projected   // 需推算（如按当前速率推算全月）
}

nonisolated enum HoloAgentComparisonAlignment: String, Equatable, Sendable {
    case aligned     // 自然对齐（本月 vs 上月，同为完整月）
    case approximate // 近似对齐（近30天 vs 上一个30天）
    case unaligned   // 不可比（不同粒度或长度）
}

/// 带元数据的解析结果。
nonisolated struct HoloAgentResolvedTimeScopeExtended: Equatable, Sendable {
    var scope: HoloAgentResolvedTimeScope
    var assumption: HoloAgentTimeAssumption
    var extendedKind: HoloAgentExtendedTimeKind?
}

// MARK: - 扩展解析器

nonisolated enum HoloAgentTimeSemanticExtended {

    /// 尝试解析扩展时间语义（季度、年初至今、工作日/周末、月至今）。
    /// 返回 nil 时回退到原有 Resolver 的单窗/双窗语义。
    static func resolveExtended(
        _ text: String,
        referenceDate: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> HoloAgentResolvedTimeScopeExtended? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: referenceDate)

        // 季度
        if let quarter = resolveQuarter(in: normalized, today: today, calendar: calendar) {
            return quarter
        }

        // 年初至今
        if let ytd = resolveYearToDate(in: normalized, today: today, calendar: calendar) {
            return ytd
        }

        // 月至今 vs 完整月
        if let mtd = resolveMonthToDate(in: normalized, today: today, calendar: calendar) {
            return mtd
        }

        // 工作日/周末
        if let weekend = resolveWeekend(in: normalized, today: today, calendar: calendar) {
            return weekend
        }
        if let weekday = resolveWeekday(in: normalized, today: today, calendar: calendar) {
            return weekday
        }

        return nil
    }

    // MARK: 季度

    private static func resolveQuarter(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScopeExtended? {
        // 匹配 Q1-Q4 / 一季度~四季度 / 第1~4季度 / 今年一季度 / 上季度
        let quarterMap: [(pattern: String, quarter: Int)] = [
            ("一季度", 1), ("二季度", 2), ("三季度", 3), ("四季度", 4),
            ("第一季度", 1), ("第二季度", 2), ("第三季度", 3), ("第四季度", 4),
            ("q1", 1), ("q2", 2), ("q3", 3), ("q4", 4),
            ("1季度", 1), ("2季度", 2), ("3季度", 3), ("4季度", 4)
        ]

        let isPrevious = text.contains("上个季度") || text.contains("上季度")
        let isCurrent = text.contains("这个季度") || text.contains("本季度") || text.contains("这季度")

        // 显式季度号
        for entry in quarterMap where text.contains(entry.pattern) {
            let (year, quarter, isComplete) = resolveQuarterYearAndNumber(
                quarter: entry.quarter, isPrevious: isPrevious, today: today, calendar: calendar
            )
            guard let range = quarterDateRange(year: year, quarter: quarter, calendar: calendar) else { return nil }
            let kind: HoloAgentExtendedTimeKind = .quarter
            let scope = HoloAgentResolvedTimeScope(
                kind: .explicitMonth, // 复用 explicitMonth kind 避免改枚举
                matchedText: entry.pattern,
                timeRange: HoloAgentTimeRange(label: "\(year)年Q\(quarter)", start: range.start, end: range.end)
            )
            return HoloAgentResolvedTimeScopeExtended(
                scope: scope,
                assumption: HoloAgentTimeAssumption(
                    assumption: "「\(entry.pattern)」解析为\(year)年第\(quarter)季度",
                    completeness: isComplete ? .complete : .partial,
                    comparisonAlignment: nil,
                    isIncompletePeriod: !isComplete
                ),
                extendedKind: kind
            )
        }

        // "本季度"/"上季度" 无显式号
        if isCurrent || isPrevious {
            let currentQuarter = (calendar.component(.month, from: today) - 1) / 3 + 1
            let (year, quarter, isComplete) = resolveQuarterYearAndNumber(
                quarter: currentQuarter, isPrevious: isPrevious, today: today, calendar: calendar
            )
            guard let range = quarterDateRange(year: year, quarter: quarter, calendar: calendar) else { return nil }
            let matched = isPrevious ? (text.contains("上个季度") ? "上个季度" : "上季度") : (text.contains("本季度") ? "本季度" : "这个季度")
            let scope = HoloAgentResolvedTimeScope(
                kind: .explicitMonth,
                matchedText: matched,
                timeRange: HoloAgentTimeRange(label: "\(year)年Q\(quarter)", start: range.start, end: range.end)
            )
            return HoloAgentResolvedTimeScopeExtended(
                scope: scope,
                assumption: HoloAgentTimeAssumption(
                    assumption: "「\(matched)」解析为\(year)年第\(quarter)季度",
                    completeness: isComplete ? .complete : .partial,
                    comparisonAlignment: nil,
                    isIncompletePeriod: !isComplete
                ),
                extendedKind: .quarter
            )
        }

        return nil
    }

    private static func resolveQuarterYearAndNumber(quarter: Int, isPrevious: Bool, today: Date, calendar: Calendar) -> (year: Int, quarter: Int, isComplete: Bool) {
        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)

        if isPrevious {
            if quarter > 1 {
                return (currentYear, quarter, true)
            } else {
                return (currentYear - 1, quarter, true)
            }
        }

        // 当前周期是否完整：季度最后一个月已过
        let quarterEndMonth = quarter * 3
        let isComplete = currentMonth > quarterEndMonth

        return (currentYear, quarter, isComplete)
    }

    private static func quarterDateRange(year: Int, quarter: Int, calendar: Calendar) -> (start: Date, end: Date)? {
        let startMonth = (quarter - 1) * 3 + 1
        guard let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)),
              let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
        return (start, end)
    }

    // MARK: 年初至今

    private static func resolveYearToDate(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScopeExtended? {
        let phrases = ["今年以来", "今年到现在", "今年至今", "年初到现在", "年初至今"]
        guard phrases.contains(where: { text.contains($0) }) else { return nil }

        let year = calendar.component(.year, from: today)
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        let scope = HoloAgentResolvedTimeScope(
            kind: .currentYear,
            matchedText: phrases.first(where: { text.contains($0) }) ?? "今年以来",
            timeRange: HoloAgentTimeRange(label: "\(year)年初至今", start: start, end: end)
        )
        return HoloAgentResolvedTimeScopeExtended(
            scope: scope,
            assumption: HoloAgentTimeAssumption(
                assumption: "「今年以来」解析为\(year)年1月1日至今天（不完整年度）",
                completeness: .partial,
                comparisonAlignment: nil,
                isIncompletePeriod: true
            ),
            extendedKind: .yearToDate
        )
    }

    // MARK: 月至今 vs 完整月

    /// 当用户说"本月"时，区分"月至今"（partial）与"完整自然月"语义。
    /// 此函数仅在需要显式标注 partial 时由 Runtime 调用，不影响原有 Resolver。
    private static func resolveMonthToDate(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScopeExtended? {
        let phrases = ["本月至今", "这个月到现在", "本月到现在", "这个月至今"]
        guard phrases.contains(where: { text.contains($0) }) else { return nil }

        guard let monthRange = calendar.dateInterval(of: .month, for: today) else { return nil }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let dayOfMonth = calendar.component(.day, from: today)
        let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30

        let scope = HoloAgentResolvedTimeScope(
            kind: .currentMonth,
            matchedText: phrases.first(where: { text.contains($0) }) ?? "本月至今",
            timeRange: HoloAgentTimeRange(label: "本月至今（第\(dayOfMonth)天）", start: monthRange.start, end: end)
        )
        return HoloAgentResolvedTimeScopeExtended(
            scope: scope,
            assumption: HoloAgentTimeAssumption(
                assumption: "本月已过\(dayOfMonth)/\(daysInMonth)天，数据为部分周期",
                completeness: .partial,
                comparisonAlignment: .unaligned,
                isIncompletePeriod: true
            ),
            extendedKind: .monthToDate
        )
    }

    // MARK: 工作日/周末

    private static func resolveWeekend(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScopeExtended? {
        let phrases = ["周末", "双休日", "休息日"]
        guard phrases.contains(where: { text.contains($0) }) else { return nil }

        guard let weekRange = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
        // 周六、周日（中文日历 weekRange.start 通常为周一）
        guard let saturday = calendar.date(byAdding: .day, value: 5, to: weekRange.start),
              let monday = calendar.date(byAdding: .day, value: 7, to: weekRange.start) else { return nil }

        let scope = HoloAgentResolvedTimeScope(
            kind: .currentWeek,
            matchedText: phrases.first(where: { text.contains($0) }) ?? "周末",
            timeRange: HoloAgentTimeRange(label: "本周末", start: saturday, end: monday)
        )
        return HoloAgentResolvedTimeScopeExtended(
            scope: scope,
            assumption: HoloAgentTimeAssumption(
                assumption: "「周末」解析为本周六日",
                completeness: .complete,
                comparisonAlignment: nil,
                isIncompletePeriod: false
            ),
            extendedKind: .weekend
        )
    }

    private static func resolveWeekday(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScopeExtended? {
        let phrases = ["工作日", "上班日", "工作日平均"]
        guard phrases.contains(where: { text.contains($0) }) else { return nil }

        guard let weekRange = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
        // 周一至周五
        guard let friday = calendar.date(byAdding: .day, value: 5, to: weekRange.start) else { return nil }

        let scope = HoloAgentResolvedTimeScope(
            kind: .currentWeek,
            matchedText: phrases.first(where: { text.contains($0) }) ?? "工作日",
            timeRange: HoloAgentTimeRange(label: "本周工作日", start: weekRange.start, end: friday)
        )
        return HoloAgentResolvedTimeScopeExtended(
            scope: scope,
            assumption: HoloAgentTimeAssumption(
                assumption: "「工作日」解析为本周一至周五",
                completeness: .complete,
                comparisonAlignment: nil,
                isIncompletePeriod: false
            ),
            extendedKind: .weekday
        )
    }
}
