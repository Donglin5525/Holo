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
        case .daily: return String(localized: "每天")
        case .weekly: return String(localized: "每周")
        case .monthly: return String(localized: "每月")
        case .yearly: return String(localized: "每年")
        case .custom: return String(localized: "自定义")
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
        case .never: return String(localized: "永不")
        case .onDate: return String(localized: "指定日期")
        case .afterCount: return String(localized: "重复次数")
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
        case .dayOfMonth: return String(localized: "固定日期")
        case .nthWeekday: return String(localized: "第N个周X")
        }
    }
}


@objc(TodoTask) class TodoTask: NSManagedObject {}
