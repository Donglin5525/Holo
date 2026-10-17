//
//  HabitStatsState.swift
//  Holo
//
//  习惯统计模块的状态管理
//  重构后：月度仪表板模式（当前自然月 + 周视图优先 + 单开展开月历）
//

import SwiftUI
import Combine

// MARK: - HabitStatsDateRange（旧接口兼容）

/// 习惯统计时间范围（区别于 HabitDateRange）
enum HabitStatsDateRange: String, CaseIterable, Identifiable {
    case week = "7"
    case month = "30"
    case quarter = "90"
    case all = "all"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: return String(localized: "7天")
        case .month: return String(localized: "30天")
        case .quarter: return String(localized: "90天")
        case .all: return String(localized: "全部")
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    func dateRange() -> ClosedRange<Date>? {
        guard let days = days else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return nil
        }
        return startDate...Date()
    }
}

// MARK: - HabitTypeFilter（旧接口兼容）

enum HabitTypeFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case checkIn = "checkIn"
    case count = "count"
    case measure = "measure"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return String(localized: "全部")
        case .checkIn: return String(localized: "打卡型")
        case .count: return String(localized: "计数类")
        case .measure: return String(localized: "测量类")
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .checkIn: return "checkmark.circle"
        case .count: return "number"
        case .measure: return "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - DailyCompletionData（旧接口兼容）

struct DailyCompletionData: Identifiable {
    let date: Date
    let completionRate: Double
    var id: Date { date }
}

// MARK: - HabitRankingItem（旧接口兼容）

struct HabitRankingItem: Identifiable {
    let habitId: UUID
    let name: String
    let icon: String
    let color: String
    let completionRate: Double
    let streak: HabitStreak
    var id: UUID { habitId }

    var habitColor: Color {
        HabitColorPresets.color(from: color)
    }
}


// MARK: - HabitOverviewStats

/// 总览统计数据
struct HabitOverviewStats {
    let todayCompleted: Int
    let totalHabits: Int
    let averageCompletionRate: Double
    let bestStreak: HabitStreak

    var todayCompletionRate: Double {
        guard totalHabits > 0 else { return 0 }
        return Double(todayCompleted) / Double(totalHabits) * 100
    }

    static func empty() -> HabitOverviewStats {
        HabitOverviewStats(
            todayCompleted: 0,
            totalHabits: 0,
            averageCompletionRate: 0,
            bestStreak: .zero()
        )
    }
}

// MARK: - 月度统计投影类型

/// 统计卡片习惯类型
enum HabitStatsCardKind: Equatable {
    case checkIn
    case count
    case measure
}

/// 月份格子中的一天
struct HabitStatsDayCell: Identifiable, Equatable {
    let date: Date
    let dayNumber: Int?
    let isInCurrentMonth: Bool
    let isToday: Bool
    /// 好习惯：有记录=成功；坏习惯：控制住=成功
    let hasRecord: Bool
    /// 坏习惯超标标记
    let isOverLimit: Bool
    /// 冻结日（暂停窗口内）：浅灰「休」样式，不红不绿
    var isPausedDay: Bool = false
    var id: Date { date }
}
