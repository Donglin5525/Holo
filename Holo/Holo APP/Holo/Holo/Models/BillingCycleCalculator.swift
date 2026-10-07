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

nonisolated struct BillingCycleCalculator {

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

    // MARK: - 记账年（年度统计口径）

    /// 记账年区间 [start, end)：以「包含 reference 的账期起点所在年份」为记账年 Y，
    /// 区间 = Y 年 1 月有效起始日 → 平移 12 个账期。
    /// startDay = 1 时与自然年等价。
    /// 例（startDay=25）：reference=2026/9/26 → 2026/1/25 – 2027/1/24；
    /// reference=2026/1/10（所在账期 2025/12/25–2026/1/24）→ 2025 记账年 2025/1/25 – 2026/1/24。
    static func billingYearRange(startDay: Int, reference: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startDay = clampedDay(startDay)
        let cycle = currentCycleRange(startDay: startDay, reference: reference, calendar: calendar)
        let year = calendar.component(.year, from: cycle.start)
        guard let januaryStart = makeDate(year: year, month: 1, day: startDay, calendar: calendar) else {
            return (cycle.start, cycle.end)
        }
        let end = shiftedCycleStart(januaryStart, startDay: startDay, offset: 12, calendar: calendar)
        return (januaryStart, end)
    }

    /// 年度区间按口径平移 offset 个年（同比上一年取 offset = -1，左右翻年取 ±1）：
    /// 自然年 = 起止各平移 offset 年；记账年 = 起止各平移 offset×12 个账期（含月底 cap）。
    static func shiftedYearRange(
        start: Date,
        end: Date,
        offset: Int,
        basis: FinanceYearBasis,
        startDay: Int,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        switch basis {
        case .calendar:
            guard let newStart = calendar.date(byAdding: .year, value: offset, to: start),
                  let newEnd = calendar.date(byAdding: .year, value: offset, to: end) else {
                return (start, end)
            }
            return (newStart, newEnd)
        case .billing:
            let monthOffset = offset * 12
            let newStart = shiftedCycleStart(start, startDay: startDay, offset: monthOffset, calendar: calendar)
            let newEnd = shiftedCycleStart(end, startDay: startDay, offset: monthOffset, calendar: calendar)
            return (newStart, newEnd)
        }
    }

    /// 已过周期数（年视图月均口径）：从 start 按月推进到 min(now, end) 的桶数，
    /// 进行中的一期也计入（「今年至今 5.2 万 ÷ 9 个月」的用户心智），封顶 12。
    /// 自然年与记账年同构（账期按月推进），无需区分口径。
    static func elapsedPeriodCount(
        from start: Date,
        to end: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let limit = min(now, end)
        guard limit > start else { return 0 }
        var count = 1
        while count < 12,
              let nextStart = calendar.date(byAdding: .month, value: count, to: start),
              nextStart < limit {
            count += 1
        }
        return count
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
