//
//  Weekday.swift
//  Holo
//
//  星期枚举和扩展
//

import Foundation

/// 星期枚举（与 Calendar 的 weekday 对应）
/// Sunday = 1, Monday = 2, ..., Saturday = 7
enum Weekday: Int, Codable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    /// 显示名称（如"周一"）
    var displayTitle: String {
        switch self {
        case .sunday: return "周日"
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        }
    }

    /// 简短显示名称（如"一"）
    var shortDisplayTitle: String {
        switch self {
        case .sunday: return "日"
        case .monday: return "一"
        case .tuesday: return "二"
        case .wednesday: return "三"
        case .thursday: return "四"
        case .friday: return "五"
        case .saturday: return "六"
        }
    }

    /// 英文缩写（如"Mon"）
    var abbreviatedName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    /// 判断是否是周末
    var isWeekend: Bool {
        self == .sunday || self == .saturday
    }

    /// 判断是否是工作日
    var isWeekday: Bool {
        !isWeekend
    }
}

// MARK: - Calendar Extension

extension Calendar {
    /// 获取当前日期的 Weekday
    var currentWeekday: Weekday? {
        let weekday = component(.weekday, from: Date())
        return Weekday(rawValue: weekday)
    }

    /// 判断日期是否是节假日（简化实现，仅判断周末）
    func isHoliday(_ date: Date) -> Bool {
        let weekday = component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // 周日或周六
    }
}
