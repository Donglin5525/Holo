//
//  BillingCycleCalculator.swift
//  Holo
//
//  账单周期日期范围计算工具
//
//  解决问题：让"一个月的统计"可以按用户自定义的起始日（1-31）来划分，
//  而不是只能按自然月（1 号到月底）。
//
//  核心难点：起始日设为 31 号时，2 月只有 28 天、4 月只有 30 天。
//  处理策略：cap 到当月最后一天（min(设定日, 当月天数)）。
//

import Foundation

struct BillingCycleCalculator {

    // MARK: - 月底 cap

    /// 把账单日 cap 到指定月份的有效日期。
    /// 例：day=31, 2月 → 28/29；day=31, 4月 → 30；day=15, 任意月 → 15。
    private static func effectiveDay(_ day: Int, year: Int, month: Int, calendar: Calendar) -> Int {
        guard let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)?.count else {
            return min(day, 28)
        }
        return min(max(day, 1), daysInMonth)
    }

    /// 构造一个具体日期（某年某月某日的 00:00:00）
    private static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        let effectiveDay = effectiveDay(day, year: year, month: month, calendar: calendar)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = effectiveDay
        return calendar.date(from: components)
    }

    // MARK: - 当前周期范围

    /// 给定起始日（1-31）和参考日期，返回包含参考日期的账单周期 [start, end)。
    ///
    /// 算法：
    /// 1. 算出"本月有效账单日"和"上月有效账单日"（cap 到当月天数）
    /// 2. 如果 reference >= 本月有效账单日 → 本周期从本月有效账单日开始
    ///    否则 → 本周期从上月有效账单日开始（reference 落在上月账单日到本月账单日之间）
    /// 3. end = start 的下一个月有效账单日
    ///
    /// 验证（startDay=31）：
    ///   reference=2/15 → 本月有效日 2/28, 上月 1/31 → start=1/31, end=2/28 ✓
    ///   reference=3/15 → 本月有效日 3/31, 上月 2/28 → start=2/28, end=3/31 ✓
    ///   reference=5/10 → 本月有效日 5/31, 上月 4/30 → start=4/30, end=5/31 ✓
    static func currentCycleRange(startDay: Int, reference: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startDay = clampedDay(startDay)
        let ref = calendar.startOfDay(for: reference)

        // 本月有效账单日
        let thisMonthComponents = calendar.dateComponents([.year, .month], from: ref)
        guard let thisYear = thisMonthComponents.year, let thisMonth = thisMonthComponents.month else {
            return (ref.startOfMonth, ref.startOfMonth.addingMonths(1))
        }
        let thisMonthEffective = makeDate(year: thisYear, month: thisMonth, day: startDay, calendar: calendar)!

        // 上月有效账单日
        let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: thisMonthEffective)!
        let lastMonthComponents = calendar.dateComponents([.year, .month], from: lastMonthDate)
        let lastMonthEffective = makeDate(year: lastMonthComponents.year!, month: lastMonthComponents.month!, day: startDay, calendar: calendar)!

        // 判断 reference 落在哪个周期
        let cycleStart: Date
        if ref >= thisMonthEffective {
            cycleStart = thisMonthEffective
        } else {
            cycleStart = lastMonthEffective
        }

        // end = 下一个月有效账单日
        let nextMonthDate = calendar.date(byAdding: .month, value: 1, to: cycleStart)!
        let nextMonthComponents = calendar.dateComponents([.year, .month], from: nextMonthDate)
        let cycleEnd = makeDate(year: nextMonthComponents.year!, month: nextMonthComponents.month!, day: startDay, calendar: calendar)!

        return (cycleStart, cycleEnd)
    }

    // MARK: - 周期平移

    /// 给定一个周期 start，算 ±N 个周期后的 start。
    /// 用于统计页左右切换月份。
    ///
    /// 算法：从 start 出发，逐月推进到 offset 对应的有效账单日。
    static func shiftedCycleStart(_ start: Date, startDay: Int, offset: Int, calendar: Calendar = .current) -> Date {
        let startDay = clampedDay(startDay)
        guard let targetDate = calendar.date(byAdding: .month, value: offset, to: start) else {
            return start
        }
        let targetComponents = calendar.dateComponents([.year, .month], from: targetDate)
        guard let targetYear = targetComponents.year, let targetMonth = targetComponents.month else {
            return start
        }
        return makeDate(year: targetYear, month: targetMonth, day: startDay, calendar: calendar) ?? start
    }

    /// 给定一个周期 start 和起始日，算该周期的 end（下一个有效账单日）。
    static func cycleEnd(from start: Date, startDay: Int, calendar: Calendar = .current) -> Date {
        shiftedCycleStart(start, startDay: startDay, offset: 1, calendar: calendar)
    }

    // MARK: - 前一个周期

    /// 给定起始日和参考日期，返回前一个账单周期范围 [start, end)。
    /// 用于环比对比。
    static func previousCycleRange(startDay: Int, reference: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let current = currentCycleRange(startDay: startDay, reference: reference, calendar: calendar)
        let prevStart = shiftedCycleStart(current.start, startDay: startDay, offset: -1, calendar: calendar)
        return (prevStart, current.start)
    }

    // MARK: - 信用卡还款日

    /// 给定账单日和还款日，算出某个周期对应的还款日。
    ///
    /// 处理跨月：
    /// - dueDay >= billingDay → 还款日在账单日同月（账单日 5，还款日 25）
    /// - dueDay < billingDay → 还款日在账单日次月（账单日 25，还款日 5 → 次月 5 号）
    ///
    /// - Parameters:
    ///   - billingDay: 账单日（1-31）
    ///   - dueDay: 还款日（1-31）
    ///   - cycleStart: 账单周期起始日
    static func dueDate(billingDay: Int, dueDay: Int, cycleStart: Date, calendar: Calendar = .current) -> Date {
        let billingDay = clampedDay(billingDay)
        let dueDay = clampedDay(dueDay)

        if dueDay >= billingDay {
            // 同月
            let components = calendar.dateComponents([.year, .month], from: cycleStart)
            return makeDate(year: components.year!, month: components.month!, day: dueDay, calendar: calendar)!
        } else {
            // 次月
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: cycleStart)!
            let components = calendar.dateComponents([.year, .month], from: nextMonth)
            return makeDate(year: components.year!, month: components.month!, day: dueDay, calendar: calendar)!
        }
    }

    // MARK: - 辅助

    /// 把 day 限制在 1-31 范围
    private static func clampedDay(_ day: Int) -> Int {
        min(max(day, 1), 31)
    }
}
