//
//  HealthMetricType.swift
//  Holo
//
//  健康指标类型枚举
//  定义应用支持的健康数据类型
//

import SwiftUI

// MARK: - HealthMetricType

/// 健康指标类型
enum HealthMetricType: String, CaseIterable, Identifiable {
    case steps = "步数"
    case sleep = "睡眠"
    case standHours = "站立"

    var id: String { rawValue }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .sleep: return "bed.double.fill"
        case .standHours: return "figure.stand"
        }
    }

    /// 指标颜色
    var color: Color {
        switch self {
        case .steps: return .holoPrimary      // #F46D38
        case .sleep: return .holoChart1       // #13A4EC
        case .standHours: return .holoPurple  // #C084FC
        }
    }

    /// 每日目标值
    var dailyGoal: Double {
        switch self {
        case .steps: return 10000
        case .sleep: return 8
        case .standHours: return 12
        }
    }

    /// 单位文本
    var unit: String {
        switch self {
        case .steps: return "步"
        case .sleep: return "小时"
        case .standHours: return "小时"
        }
    }

    /// 格式化显示值
    func formatValue(_ value: Double) -> String {
        switch self {
        case .steps:
            return Int(value).formatted()
        case .sleep, .standHours:
            return String(format: "%.1f", value)
        }
    }

    /// 格式化显示值（带单位）
    func formatValueWithUnit(_ value: Double) -> String {
        return "\(formatValue(value)) \(unit)"
    }
}

// MARK: - HealthMetricData

/// 单日健康数据
struct HealthMetricData: Identifiable {
    let type: HealthMetricType
    let date: Date
    let value: Double

    var id: Date { date }

    /// 完成百分比（0-100）
    var progress: Double {
        guard type.dailyGoal > 0 else { return 0 }
        return min(value / type.dailyGoal * 100, 100)
    }

    /// 是否达成目标
    var isGoalMet: Bool {
        return value >= type.dailyGoal
    }
}

// MARK: - DailyHealthData

/// 每日健康数据（用于趋势图）
struct DailyHealthData: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }

    /// 格式化日期（MM-dd）
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    /// 格式化星期
    var formattedWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
