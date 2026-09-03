//
//  ChineseLunarCalendar.swift
//  Holo
//
//  农历支持：公历 ↔ 农历换算与农历重复推算（系统 chinese 日历封装）
//

import Foundation

/// 农历工具（线程安全，纯计算）
enum ChineseLunarCalendar {

    private static let lunar = Calendar(identifier: .chinese)

    // MARK: - 公历 → 农历

    /// 某公历日期的农历月份数字（1-12，闰月与正常月同号）
    static func lunarMonth(of date: Date) -> Int {
        let comps = lunar.dateComponents([.month], from: date)
        return comps.month ?? 1
    }

    /// 某公历日期的农历日数字（1-30）
    static func lunarDay(of date: Date) -> Int {
        let comps = lunar.dateComponents([.day], from: date)
        return comps.day ?? 1
    }

    /// 农历月文案：「正月」「八月」「冬月」「腊月」「闰四月」
    static func lunarMonthText(month: Int, isLeap: Bool) -> String {
        let names = ["正月", "二月", "三月", "四月", "五月", "六月",
                     "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let base = names[(month - 1) % 12]
        return isLeap ? String(localized: "闰\(base)") : String(localized: String.LocalizationValue(base))
    }

    /// 农历日文案：初一 / 初二 / … / 十五 / … / 廿一 / … / 三十
    static func lunarDayText(day: Int) -> String {
        let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        switch day {
        case 1...10:
            return String(localized: "初\(digits[day - 1])")
        case 11...19:
            return String(localized: "十\(digits[day - 11])")
        case 20:
            return String(localized: "二十")
        case 21...29:
            return String(localized: "廿\(digits[day - 21])")
        case 30:
            return String(localized: "三十")
        default:
            return "\(day)"
        }
    }

    /// 完整农历日文案：「八月廿一」
    static func lunarDateText(of date: Date) -> String {
        let comps = lunar.dateComponents([.month, .day], from: date)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let monthText = lunarMonthText(month: month, isLeap: comps.isLeapMonth ?? false)
        let dayText = lunarDayText(day: day)
        return "\(monthText)\(dayText)"
    }

    // MARK: - 农历重复推算

    /// 找到「不早于 reference」、农历月日与 origin 相同的下一个公历日。
    ///
    /// 采用时间线搜索而非农历年份加一，避开 chinese 日历 era/year 的换算坑；
    /// 搜索窗口 400 天覆盖一个完整农历年（含闰月年 383-385 天）。
    /// - Note: 匹配农历月+日（不比较闰月标志），闰月年份按常规月匹配
    static func nextLunarOccurrence(of origin: Date, onOrAfter reference: Date) -> Date {
        let gregorian = Calendar.current
        let targetMonth = lunarMonth(of: origin)
        let targetDay = lunarDay(of: origin)

        var cursor = gregorian.startOfDay(for: reference)
        for _ in 0..<400 {
            if lunarMonth(of: cursor) == targetMonth && lunarDay(of: cursor) == targetDay {
                return cursor
            }
            guard let next = gregorian.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // 理论上不可达（400 天内必有一个农历同月日），兜底返回一年后
        return gregorian.date(byAdding: .year, value: 1, to: gregorian.startOfDay(for: reference))
            ?? gregorian.startOfDay(for: reference)
    }

    /// 找到「早于 reference」、农历月日与 origin 相同的最近一个公历日（年度周期进度用）
    static func previousLunarOccurrence(of origin: Date, before reference: Date) -> Date {
        let gregorian = Calendar.current
        let targetMonth = lunarMonth(of: origin)
        let targetDay = lunarDay(of: origin)

        var cursor = gregorian.startOfDay(for: reference)
        for _ in 0..<400 {
            if lunarMonth(of: cursor) == targetMonth && lunarDay(of: cursor) == targetDay {
                return cursor
            }
            guard let prev = gregorian.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return gregorian.startOfDay(for: origin)
    }
}
