//
//  CalendarHelpers.swift
//  Holo
//
//  日期计算工具 — 周/月起止日、网格生成、格式化
//

import Foundation

// MARK: - Date 扩展

extension Date {
    
    /// 获取所在周的周一（中文习惯：周一起始）
    var startOfWeek: Date {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: self)
        let offset = (wd + 5) % 7
        return cal.date(byAdding: .day, value: -offset, to: self.startOfDay) ?? self
    }
    
    /// 当天 00:00:00
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    
    /// 所在月第一天
    var startOfMonth: Date {
        let c = Calendar.current.dateComponents([.year, .month], from: self)
        return Calendar.current.date(from: c) ?? self
    }
    
    /// 当月天数
    var daysInMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: self)?.count ?? 30
    }
    
    var isToday: Bool { Calendar.current.isDateInToday(self) }
    
    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }
    
    func isSameMonth(as other: Date) -> Bool {
        let c = Calendar.current
        return c.component(.year, from: self) == c.component(.year, from: other)
            && c.component(.month, from: self) == c.component(.month, from: other)
    }
    
    var isWeekend: Bool {
        let wd = Calendar.current.component(.weekday, from: self)
        return wd == 1 || wd == 7
    }
    
    func addingDays(_ d: Int) -> Date { Calendar.current.date(byAdding: .day, value: d, to: self) ?? self }
    func addingMonths(_ m: Int) -> Date { Calendar.current.date(byAdding: .month, value: m, to: self) ?? self }
    func addingWeeks(_ w: Int) -> Date { Calendar.current.date(byAdding: .weekOfYear, value: w, to: self) ?? self }
}

// MARK: - 月历网格生成

struct CalendarGridGenerator {
    /// 生成月历网格日期数组（35 或 42 个，含上下月补位）
    static func generateGrid(for month: Date) -> [Date] {
        let cal = Calendar.current
        let first = month.startOfMonth
        let wd = cal.component(.weekday, from: first)
        let offset = (wd + 5) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -offset, to: first) else { return [] }
        let total = (offset + month.daysInMonth) > 35 ? 42 : 35
        return (0..<total).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }
    
    /// 生成周 7 天数组
    static func generateWeekDays(from weekStart: Date) -> [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }
}

// MARK: - 日期格式化

struct CalendarDateFormatter {
    static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]
    
    static func monthTitle(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月"
        return f.string(from: date)
    }
    
    /// 金额紧凑格式（<1000 整数，≥1000 用 k）
    static func compactAmount(_ amount: Decimal) -> String {
        let v = NSDecimalNumber(decimal: amount).doubleValue
        if v < 1000 { return String(format: "%.0f", v) }
        else if v < 10000 { return String(format: "%.1fk", v / 1000) }
        else { return String(format: "%.0fk", v / 1000) }
    }
}
