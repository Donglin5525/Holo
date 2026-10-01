//
//  FinanceAnalysisNavigation.swift
//  Holo
//
//  财务统计日期窗口导航与异步加载仲裁。
//

import Foundation

enum FinanceDateRangeNavigationDirection {
    case previous
    case next

    var multiplier: Int { self == .previous ? -1 : 1 }
}

/// 统一计算统计页左右切换后的日期窗口。
/// 自定义窗口如果恰好是自然月/账单周期，仍按对应周期切换；其他窗口按原自然日跨度平移。
struct FinanceDateRangeNavigator {
    static func shiftedRange(
        start: Date,
        end: Date,
        timeRange: TimeRange,
        direction: FinanceDateRangeNavigationDirection,
        yearBasis: FinanceYearBasis = .calendar,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard end > start else { return nil }

        let resolvedRange = timeRange == .custom
            ? inferredPresetRange(start: start, end: end, calendar: calendar)
            : timeRange

        if let resolvedRange, resolvedRange != .custom {
            // 月维度走账单周期平移逻辑
            if resolvedRange == .month {
                let startDay = FinancePeriodSettings.shared.billingCycleStartDay
                let newStart = BillingCycleCalculator.shiftedCycleStart(
                    start, startDay: startDay, offset: direction.multiplier, calendar: calendar
                )
                let newEnd = BillingCycleCalculator.cycleEnd(from: newStart, startDay: startDay, calendar: calendar)
                return (newStart, newEnd)
            }

            // 年维度按口径平移（记账年 = 12 个账期，自然年 = 日历年）
            if resolvedRange == .year {
                let shifted = BillingCycleCalculator.shiftedYearRange(
                    start: start,
                    end: end,
                    offset: direction.multiplier,
                    basis: yearBasis,
                    startDay: FinancePeriodSettings.shared.billingCycleStartDay,
                    calendar: calendar
                )
                return shifted
            }

            guard let newStart = shiftedStart(
                start,
                timeRange: resolvedRange,
                multiplier: direction.multiplier,
                calendar: calendar
            ), let newEnd = endDate(for: newStart, timeRange: resolvedRange, calendar: calendar) else {
                return nil
            }
            return (newStart, newEnd)
        }

        let daySpan = max(calendar.dateComponents([.day], from: start, to: end).day ?? 1, 1)
        guard let newStart = calendar.date(
            byAdding: .day,
            value: direction.multiplier * daySpan,
            to: start
        ), let newEnd = calendar.date(
            byAdding: .day,
            value: direction.multiplier * daySpan,
            to: end
        ) else {
            return nil
        }
        return (newStart, newEnd)
    }

    private static func inferredPresetRange(
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> TimeRange? {
        if calendar.component(.month, from: start) == 1,
           calendar.component(.day, from: start) == 1,
           calendar.date(byAdding: .year, value: 1, to: start) == end {
            return .year
        }
        if calendar.component(.day, from: start) == 1,
           calendar.date(byAdding: .month, value: 3, to: start) == end {
            return .quarter
        }
        // 判断是否为账单周期（含自然月）：如果 start 日 == 全局起始日 且 end == 下一个周期起始日
        let startDay = FinancePeriodSettings.shared.billingCycleStartDay
        let startDayComponent = calendar.component(.day, from: start)
        let expectedEnd = BillingCycleCalculator.cycleEnd(from: start, startDay: startDay, calendar: calendar)
        if startDayComponent == startDay && calendar.isDate(expectedEnd, inSameDayAs: end) {
            return .month
        }
        // 兼容自然月（旧自定义范围）
        if calendar.component(.day, from: start) == 1,
           calendar.date(byAdding: .month, value: 1, to: start) == end {
            return .month
        }
        // 记账年窗口：start 为某年 1 月的有效起始日且 end == 平移 12 个账期
        //（自然年窗口已在上方命中；此处只补 startDay≠1 的记账年）
        if calendar.component(.month, from: start) == 1,
           startDayComponent == startDay,
           BillingCycleCalculator.shiftedCycleStart(start, startDay: startDay, offset: 12, calendar: calendar) == end {
            return .year
        }
        return nil
    }

    private static func shiftedStart(
        _ start: Date,
        timeRange: TimeRange,
        multiplier: Int,
        calendar: Calendar
    ) -> Date? {
        switch timeRange {
        case .day:
            return calendar.date(byAdding: .day, value: multiplier, to: start)
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: multiplier, to: start)
        case .month:
            return calendar.date(byAdding: .month, value: multiplier, to: start)
        case .quarter:
            return calendar.date(byAdding: .month, value: 3 * multiplier, to: start)
        case .year:
            return calendar.date(byAdding: .year, value: multiplier, to: start)
        case .custom:
            return nil
        }
    }

    private static func endDate(
        for start: Date,
        timeRange: TimeRange,
        calendar: Calendar
    ) -> Date? {
        switch timeRange {
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: start)
        case .week:
            return calendar.date(byAdding: .day, value: 7, to: start)
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: start)
        case .quarter:
            return calendar.date(byAdding: .month, value: 3, to: start)
        case .year:
            return calendar.date(byAdding: .year, value: 1, to: start)
        case .custom:
            return nil
        }
    }
}

/// 防止较早发起的异步加载覆盖用户最后一次选择。
struct FinanceAnalysisLoadGate {
    private(set) var latestGeneration = 0

    mutating func begin() -> Int {
        latestGeneration += 1
        return latestGeneration
    }

    func accepts(_ generation: Int) -> Bool {
        generation == latestGeneration
    }
}

/// 翻页闸门：窗口末端已越过 now（当前或未来周期）时禁用右翻，
/// 杜绝一路翻进没有任何记录的未来；左翻不设限（历史随时可看）。
enum FinanceAnalysisNextGate {
    static func canNavigateNext(rangeEnd: Date, now: Date) -> Bool {
        rangeEnd <= now
    }
}
