//
//  TodoTaskModels.swift
//  Holo
//
//  待办模块辅助模型
//

import Foundation
import CoreData
import Combine

// MARK: - RepeatType

/// 重复任务类型
enum RepeatType: String, Codable, CaseIterable {
    case daily = "daily"           // 每天
    case weekly = "weekly"         // 每周
    case monthly = "monthly"       // 每月
    case yearly = "yearly"         // 每年
    case custom = "custom"         // 自定义

    var displayTitle: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        case .custom: return "自定义"
        }
    }

    var iconName: String {
        switch self {
        case .daily: return "sun.max"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .yearly: return "calendar.circle"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - EndConditionType

/// 重复结束条件类型
enum EndConditionType: String, Codable, CaseIterable {
    case never = "never"              // 永不结束
    case onDate = "onDate"            // 指定日期结束
    case afterCount = "afterCount"    // 重复N次后结束

    var displayTitle: String {
        switch self {
        case .never: return "永不"
        case .onDate: return "指定日期"
        case .afterCount: return "重复次数"
        }
    }
}

// MARK: - MonthlyRepeatMode

/// 每月重复模式
enum MonthlyRepeatMode: String, Codable, CaseIterable {
    case dayOfMonth = "dayOfMonth"     // 每月固定日期
    case nthWeekday = "nthWeekday"     // 每月第N个周X

    var displayTitle: String {
        switch self {
        case .dayOfMonth: return "固定日期"
        case .nthWeekday: return "第N个周X"
        }
    }
}

// MARK: - TaskReminder

/// 任务提醒
struct TaskReminder: Identifiable, Codable {
    let id: UUID
    var offsetMinutes: Int // 相对于截止时间的分钟数（负数表示提前）
    var displayTitle: String {
        switch offsetMinutes {
        case 0: return "截止时间"
        case 5: return "5 分钟前"
        case 15: return "15 分钟前"
        case 30: return "30 分钟前"
        case 60: return "1 小时前"
        case 1440: return "1 天前"
        default: return "\(abs(offsetMinutes)) 分钟"
        }
    }

    init(id: UUID = UUID(), offsetMinutes: Int = 0) {
        self.id = id
        self.offsetMinutes = offsetMinutes
    }

    /// 预设的提醒选项
    static let presetOptions: [TaskReminder] = [
        TaskReminder(offsetMinutes: 0),
        TaskReminder(offsetMinutes: 5),
        TaskReminder(offsetMinutes: 15),
        TaskReminder(offsetMinutes: 30),
        TaskReminder(offsetMinutes: 60),
        TaskReminder(offsetMinutes: 1440)
    ]
}

// MARK: - Date Extensions for Task

extension Calendar {
    /// 判断是否是今天
    func isToday(_ date: Date) -> Bool {
        isDateInToday(date)
    }

    /// 判断是否是明天
    func isTomorrow(_ date: Date) -> Bool {
        isDateInTomorrow(date)
    }

    /// 判断是否是昨天
    func isYesterday(_ date: Date) -> Bool {
        isDateInYesterday(date)
    }

    /// 获取某天的开始时间
    func startOfDay(_ date: Date) -> Date {
        startOfDay(for: date)
    }

    /// 获取某天的结束时间
    func endOfDay(_ date: Date) -> Date {
        let components = DateComponents(hour: 23, minute: 59, second: 59)
        return self.date(byAdding: components, to: startOfDay(for: date)) ?? date
    }

    /// 判断两个日期是否在同一天
    func isDate(_ date1: Date, inSameDayAs date2: Date) -> Bool {
        isDate(date1, equalTo: date2, toGranularity: .day)
    }
}

extension Date {
    /// 格式化日期为相对描述
    func relativeToNow() -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(self) {
            return "今天"
        } else if calendar.isDateInTomorrow(self) {
            return "明天"
        } else if calendar.isDateInYesterday(self) {
            return "昨天"
        } else if self > now {
            // 未来日期
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd"
            return formatter.string(from: self)
        } else {
            // 过去日期
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd"
            return formatter.string(from: self)
        }
    }

    /// 判断是否已过期
    var isOverdue: Bool {
        self < Date()
    }
}
