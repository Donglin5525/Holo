//
//  HabitType.swift
//  Holo
//
//  习惯相关枚举定义
//  包含习惯类型、频率类型、聚合类型等
//

import Foundation
import SwiftUI

// MARK: - 习惯类型枚举

/// 习惯类型
/// - checkIn: 打卡型，记录完成/未完成状态
/// - numeric: 数值型，记录具体数值（如体重、抽烟次数）
enum HabitType: Int16, CaseIterable, Identifiable {
    case checkIn = 0   // 打卡型
    case numeric = 1   // 数值型
    
    var id: Int16 { rawValue }
    
    /// 显示名称
    var displayName: String {
        switch self {
        case .checkIn: return "打卡型"
        case .numeric: return "数值型"
        }
    }
    
    /// 描述说明
    var description: String {
        switch self {
        case .checkIn: return "记录每日完成状态，追踪连续天数"
        case .numeric: return "记录具体数值，支持趋势分析"
        }
    }
}

// MARK: - 习惯频率枚举

/// 习惯频率
/// 决定目标周期和统计维度
enum HabitFrequency: String, CaseIterable, Identifiable {
    case daily = "daily"     // 每日
    case weekly = "weekly"   // 每周
    case monthly = "monthly" // 每月
    
    var id: String { rawValue }
    
    /// 显示名称
    var displayName: String {
        switch self {
        case .daily: return "每日"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }
    
    /// 周期天数（用于计算）
    var periodDays: Int {
        switch self {
        case .daily: return 1
        case .weekly: return 7
        case .monthly: return 30
        }
    }
}

// MARK: - 聚合类型枚举

/// 数值型习惯的聚合方式
/// - sum: 求和聚合（计数类，如抽烟次数）
/// - latest: 取最新值（测量类，如体重）
enum HabitAggregationType: Int16, CaseIterable, Identifiable {
    case sum = 0     // 求和（计数类）
    case latest = 1  // 取最新值（测量类）
    
    var id: Int16 { rawValue }
    
    /// 显示名称
    var displayName: String {
        switch self {
        case .sum: return "计数类"
        case .latest: return "测量类"
        }
    }
    
    /// 描述说明
    var description: String {
        switch self {
        case .sum: return "累计当日总数（如抽烟次数）"
        case .latest: return "显示当日最新值（如体重）"
        }
    }
}

// MARK: - 时间范围枚举

/// 详情页时间范围选择
enum HabitDateRange: String, CaseIterable, Identifiable {
    case week = "7"      // 近 7 天
    case month = "30"    // 近 30 天
    case quarter = "90"  // 近 90 天
    case all = "all"     // 全部
    
    var id: String { rawValue }
    
    /// 显示名称
    var displayName: String {
        switch self {
        case .week: return "近7天"
        case .month: return "近30天"
        case .quarter: return "近90天"
        case .all: return "全部"
        }
    }
    
    /// 天数（nil 表示全部）
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }
    
    /// 获取日期范围
    /// - Returns: 起始日期到今天的 ClosedRange，全部时返回 nil
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

// MARK: - 预设图标

/// 习惯预设图标列表
struct HabitIconPresets {
    /// SF Symbol 图标名称列表
    static let icons: [String] = [
        "checkmark.circle",
        "flame.fill",
        "drop.fill",
        "bed.double.fill",
        "figure.walk",
        "figure.run",
        "dumbbell.fill",
        "heart.fill",
        "brain.head.profile",
        "book.fill",
        "pencil",
        "cup.and.saucer.fill",
        "leaf.fill",
        "moon.fill",
        "sun.max.fill",
        "pill.fill",
        "cross.case.fill",
        "scalemass.fill",
        "smoke.fill",
        "fork.knife"
    ]
}

// MARK: - 预设颜色

/// 习惯预设颜色列表
struct HabitColorPresets {
    /// Hex 颜色值列表
    static let colors: [String] = [
        "#13A4EC",  // 蓝色
        "#10B981",  // 绿色
        "#F59E0B",  // 琥珀色
        "#EF4444",  // 红色
        "#8B5CF6",  // 紫色
        "#EC4899",  // 粉色
        "#F97316",  // 橙色
        "#06B6D4",  // 青色
        "#84CC16",  // 柠檬绿
        "#6366F1"   // 靛蓝色
    ]
    
    /// 将 Hex 转换为 Color
    static func color(from hex: String) -> Color {
        Color(hex: hex) ?? .holoInfo
    }
}
