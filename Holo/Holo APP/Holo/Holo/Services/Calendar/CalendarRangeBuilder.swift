//
//  CalendarRangeBuilder.swift
//  Holo
//
//  日历区间生成（统一半开区间 [start, end)，周一首）
//
//  存在意义：4 模块现有区间语义不一致（Finance 半开 / Habit 闭 / Todo 同文件内一半开一闭），
//  日历聚合必须用统一的半开区间，否则跨周/跨月会重复计数或漏数。
//

import Foundation

enum CalendarRangeBuilder {

    /// DateInterval.contains 在系统实现中包含 end；业务查询统一使用半开区间。
    static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }

    /// 周一首的日历（沿用 HabitRepository+Stats 的 firstWeekday=2 约定）
    private static var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    /// 取某日所在周的区间 `[weekStart, nextWeekStart)`（周一首）
    static func weekRange(around date: Date) -> DateInterval {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return dayRange(date)
        }
        return weekInterval
    }

    /// 取某日的区间 `[startOfDay, nextStartOfDay)`
    static func dayRange(_ date: Date) -> DateInterval {
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else {
            return DateInterval(start: date, end: date)
        }
        return dayInterval
    }

    /// 取某日所在月的区间 `[monthStart, nextMonthStart)`（P1B 月历用，先行备出）
    static func monthRange(_ date: Date) -> DateInterval {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date) else {
            return dayRange(date)
        }
        return monthInterval
    }
}
