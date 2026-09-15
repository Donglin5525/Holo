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
    case steps = "steps"
    case sleep = "sleep"
    case standHours = "standHours"
    case activeMinutes = "activeMinutes"
    case workout = "workout"

    var id: String { rawValue }

    /// 显示名称（rawValue 仅作标识，不落库不传输，显示一律走 displayName）
    var displayName: String {
        switch self {
        case .steps: return String(localized: "步数")
        case .sleep: return String(localized: "睡眠")
        case .standHours: return String(localized: "站立")
        case .activeMinutes: return String(localized: "活动")
        case .workout: return String(localized: "运动")
        }
    }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .sleep: return "bed.double.fill"
        case .standHours: return "figure.stand"
        case .activeMinutes: return "figure.walk.motion"
        case .workout: return "figure.run"
        }
    }

    /// 指标颜色
    var color: Color {
        switch self {
        case .steps: return .holoPrimary      // #F46D38
        case .sleep: return .holoChart1       // #13A4EC
        case .standHours: return .holoPurple  // #C084FC
        case .activeMinutes: return .holoChart6 // #14B8A6
        case .workout: return .holoChart3     // #22C55E
        }
    }

    /// 每日目标值
    var dailyGoal: Double {
        switch self {
        case .steps: return HealthThresholds.stepsDailyGoal
        case .sleep: return HealthThresholds.sleepGoalHours
        case .standHours: return HealthThresholds.standGoalHours
        case .activeMinutes: return HealthThresholds.activityGoalMinutes
        case .workout: return HealthThresholds.workoutGoalMinutes
        }
    }

    /// 单位文本
    var unit: String {
        switch self {
        case .steps: return String(localized: "步")
        case .sleep: return String(localized: "小时")
        case .standHours: return String(localized: "小时")
        case .activeMinutes: return String(localized: "分钟")
        case .workout: return String(localized: "分钟")
        }
    }

    /// 格式化显示值
    func formatValue(_ value: Double) -> String {
        switch self {
        case .steps:
            return Int(value).formatted()
        case .sleep, .standHours:
            return String(format: "%.1f", value)
        case .activeMinutes, .workout:
            return Int(value).formatted()
        }
    }

    /// 格式化显示值（带单位）
    func formatValueWithUnit(_ value: Double) -> String {
        return "\(formatValue(value)) \(unit)"
    }
}

// MARK: - HealthThresholds

/// 健康模块口径常量（单一事实源）。
/// 界面分档、看板胶囊、AI 工具、洞察生成共用，禁止在消费方裸写数值——
/// 两处各写一份迟早漂移（曾出现 8 小时目标在 4 处重复裸写）。
enum HealthThresholds {
    // 每日目标
    static let stepsDailyGoal: Double = 10000
    static let sleepGoalHours: Double = 8
    static let standGoalHours: Double = 12
    static let activityGoalMinutes: Double = 30
    /// 运动目标（分钟）＝「运动充足日」判定口径，复用同一常量
    static let workoutGoalMinutes: Double = 30

    // 睡眠分档（看板质量胶囊、详情页标题共用）
    static let sleepQualityGoodHours: Double = 7
    static let sleepQualityFairHours: Double = 6
    /// AI 工具低睡眠日
    static let sleepLowHours: Double = 6
    /// 核心洞察文案分档（介于「好」与「低」之间的中性带不再触发专门文案）
    static let sleepInsightGoodHours: Double = 7.5
    static let sleepInsightLowHours: Double = 6.5

    // 异常判定（HealthAnalysisContextBuilder 进 AI 提示词的异常标注）
    static let lowStepsThreshold: Double = 3000
    static let anomalyConsecutiveDays = 3

    // 分析窗口
    /// 健康洞察分析窗口（天）
    static let insightWindowDays = 14
    /// 身体状态页基线窗口（天）
    static let vitalsWindowDays = 30

    /// 生活方式洞察的咖啡关键词（中英文流水都命中）
    static let coffeeKeywords = ["咖啡", "coffee"]
}

// MARK: - HealthDayData

/// 单日健康数据合集（健康主页/详情页一次取数的结果）。
/// 用结构体替代逐字段元组：运动会话上线后字段继续增多，元组不可维护。
struct HealthDayData: Equatable, Sendable {
    var steps: Double = 0
    var sleep: Double = 0
    var standHours: Double = 0
    var activeMinutes: Double = 0
    /// 当日运动总分钟（由会话列表折叠）
    var workoutMinutes: Double = 0
    /// 当日运动会话明细（详情页会话列表卡用）
    var workoutSessions: [WorkoutSessionData] = []
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

    /// 格式化星期（跟随系统语言）
    var formattedWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

// MARK: - DailyWorkoutData

/// 每日运动会话数据（HKWorkout 聚合，供健康洞察跨域证据使用）。
/// 与 DailyHealthData 区分：后者是 HealthKit 数值型指标（步数/睡眠等），此处是锻炼会话维度。
struct DailyWorkoutData: Equatable, Sendable {
    let date: Date
    /// 当日所有锻炼会话时长之和（分钟）
    let totalMinutes: Double
    /// 当日锻炼会话条数
    let sessionCount: Int
    /// 当日时长最长的运动类型中文名（如「跑步」），无运动则 nil
    let topType: String?
}
