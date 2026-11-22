//
//  MemoryAlmanac.swift
//  Holo
//
//  记忆长廊年鉴卡的纯值模型与生成器。
//  输入「按天件数」+ 今天 + 开始记录日，输出一整年 12 个月的结构，供年鉴卡（D：月度条 + 展开刻度）
//  与年鉴分享图（A：12×31 点阵）共用。无 I/O、无全局状态，便于单测。
//  方案：docs/_common/plans/2026-11-21-记忆长廊年鉴卡/01-方案.md
//

import Foundation

/// 某一年的年鉴
struct MemoryAlmanacYear: Equatable {
    let year: Int
    /// 恒为 12 个月
    let months: [MemoryAlmanacMonth]
    /// 有记录的天数（卡片大数字）
    let recordedDays: Int
    /// 件数合计
    let totalCount: Int
    /// 今年第几天；仅「今天所在年」有值
    let dayOfYear: Int?
    /// 开始记录日落在本年时有值（新用户副行「从 X 开始记录」）
    let startDate: Date?

    /// 今天所在的月份（往年为 nil），年鉴卡默认展开它
    var currentMonth: Int? { months.first { $0.state == .current }?.month }
    /// 整年都还没开始（从未记录，或开始日在本年之后）
    var hasNotStarted: Bool { months.allSatisfy { $0.state == .notStarted || $0.state == .future } && recordedDays == 0 }
}

/// 年鉴中的一个月
struct MemoryAlmanacMonth: Equatable, Identifiable {
    enum State: Equatable {
        /// 整月都在开始记录日之前
        case notStarted
        /// 已过去的月份
        case past
        /// 今天所在的月份
        case current
        /// 尚未到来的月份
        case future
    }

    let month: Int
    let state: State
    let recordedDays: Int
    let dayCount: Int
    let days: [MemoryAlmanacDay]

    var id: Int { month }
    /// 月度条长度比例（0~1）
    var fillRatio: Double { dayCount > 0 ? Double(recordedDays) / Double(dayCount) : 0 }
    /// 是否已经发生（可展开、可选日）
    var hasHappened: Bool { state == .past || state == .current }
}

/// 年鉴中的一天
struct MemoryAlmanacDay: Equatable, Identifiable {
    enum Kind: Equatable {
        /// 开始记录日之前
        case notStarted
        /// 已过去（含没记的日子，此时 level == 0）
        case past
        /// 今天
        case today
        /// 未来
        case future
    }

    let date: Date
    let count: Int
    /// 0 没记 / 1 少（1–2 件）/ 2 中（3–5 件）/ 3 多（6 件以上）
    let level: Int
    let kind: Kind

    var id: Date { date }
    /// 可被选中查看当天轨迹
    var isSelectable: Bool { kind == .past || kind == .today }

    /// 3 档：卡片刻度高度与分享图点阵深浅共用
    static func level(for count: Int) -> Int {
        switch count {
        case ...0: return 0
        case 1...2: return 1
        case 3...5: return 2
        default: return 3
        }
    }
}

/// 年鉴生成器（纯函数）
enum MemoryAlmanacBuilder {

    static func build(
        year: Int,
        dayCounts: [Date: Int],
        today: Date,
        firstRecordDate: Date?,
        calendar: Calendar = .current
    ) -> MemoryAlmanacYear {
        let todayStart = calendar.startOfDay(for: today)
        let startDay = firstRecordDate.map { calendar.startOfDay(for: $0) }
        let normalized = normalize(dayCounts, calendar: calendar)

        let months = (1...12).map { month in
            buildMonth(year: year, month: month, counts: normalized, today: todayStart, startDay: startDay, calendar: calendar)
        }
        let countedDays = months.flatMap(\.days).filter { $0.isSelectable && $0.count > 0 }
        let isCurrentYear = calendar.component(.year, from: todayStart) == year
        let startInYear = startDay.flatMap { calendar.component(.year, from: $0) == year ? $0 : nil }

        return MemoryAlmanacYear(
            year: year,
            months: months,
            recordedDays: countedDays.count,
            totalCount: countedDays.reduce(0) { $0 + $1.count },
            dayOfYear: isCurrentYear ? calendar.ordinality(of: .day, in: .year, for: todayStart) : nil,
            startDate: startInYear
        )
    }

    // MARK: - 私有

    /// 同一天不同时刻的键合并到当天零点
    private static func normalize(_ counts: [Date: Int], calendar: Calendar) -> [Date: Int] {
        counts.reduce(into: [Date: Int]()) { result, entry in
            result[calendar.startOfDay(for: entry.key), default: 0] += max(entry.value, 0)
        }
    }

    private static func buildMonth(
        year: Int,
        month: Int,
        counts: [Date: Int],
        today: Date,
        startDay: Date?,
        calendar: Calendar
    ) -> MemoryAlmanacMonth {
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return MemoryAlmanacMonth(month: month, state: .future, recordedDays: 0, dayCount: 0, days: [])
        }

        let days: [MemoryAlmanacDay] = range.compactMap { dayNumber in
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: firstOfMonth) else { return nil }
            let count = counts[date] ?? 0
            return MemoryAlmanacDay(
                date: date,
                count: count,
                level: MemoryAlmanacDay.level(for: count),
                kind: kind(of: date, today: today, startDay: startDay)
            )
        }

        return MemoryAlmanacMonth(
            month: month,
            state: state(of: days, today: today, calendar: calendar),
            recordedDays: days.filter { $0.isSelectable && $0.count > 0 }.count,
            dayCount: days.count,
            days: days
        )
    }

    private static func kind(of date: Date, today: Date, startDay: Date?) -> MemoryAlmanacDay.Kind {
        if date == today { return .today }
        if date > today { return .future }
        // 从未记录（startDay 为 nil）时，过去的日子都算「还没开始」
        guard let startDay, date >= startDay else { return .notStarted }
        return .past
    }

    private static func state(of days: [MemoryAlmanacDay], today: Date, calendar: Calendar) -> MemoryAlmanacMonth.State {
        if days.contains(where: { $0.kind == .today }) { return .current }
        if days.allSatisfy({ $0.kind == .future }) { return .future }
        if days.allSatisfy({ $0.kind == .notStarted }) { return .notStarted }
        return .past
    }
}
