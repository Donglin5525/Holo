//
//  BudgetPeriod.swift
//  Holo
//
//  预算周期枚举定义
//

import Foundation

/// 预算周期类型
enum BudgetPeriod: String, CaseIterable, Identifiable {
    case week = "week"
    case month = "month"
    case year = "year"

    var id: String { rawValue }

    /// 显示名称
    var displayName: String {
        switch self {
        case .week: return "每周"
        case .month: return "每月"
        case .year: return "每年"
        }
    }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .week: return "calendar.badge.clock"
        case .month: return "calendar"
        case .year: return "calendar.badge.plus"
        }
    }

    /// 对应的 Calendar.Component，用于周期日期计算
    var calendarComponent: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}
