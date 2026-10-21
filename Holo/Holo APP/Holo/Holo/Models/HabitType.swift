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
        case .checkIn: return String(localized: "打卡型")
        case .numeric: return String(localized: "数值型")
        }
    }

    /// 描述说明
    var description: String {
        switch self {
        case .checkIn: return String(localized: "记录每日完成状态，追踪连续天数")
        case .numeric: return String(localized: "记录具体数值，支持趋势分析")
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
        case .daily: return String(localized: "每日")
        case .weekly: return String(localized: "每周")
        case .monthly: return String(localized: "每月")
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

// MARK: - 连续性单位

/// 连续性统计单位
enum HabitStreakUnit: String, Equatable {
    case day = "day"
    case week = "week"
    case month = "month"

    /// 显示名称（rawValue 仅作标识，不落库不传输，显示一律走 displayName）
    var displayName: String {
        switch self {
        case .day: return String(localized: "天")
        case .week: return String(localized: "周")
        case .month: return String(localized: "月")
        }
    }
}

/// 习惯连续坚持信息
struct HabitStreak: Equatable {
    let value: Int
    let unit: HabitStreakUnit

    /// 显示文本（如 "3天"、"2周"、"1月"）
    var displayText: String {
        "\(value)\(unit.displayName)"
    }

    static func zero(_ unit: HabitStreakUnit = .day) -> HabitStreak {
        HabitStreak(value: 0, unit: unit)
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
        case .sum: return String(localized: "计数类")
        case .latest: return String(localized: "测量类")
        }
    }

    /// 描述说明
    var description: String {
        switch self {
        case .sum: return String(localized: "累计当日总数（如抽烟次数）")
        case .latest: return String(localized: "显示当日最新值（如体重）")
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
        case .week: return String(localized: "近7天")
        case .month: return String(localized: "近30天")
        case .quarter: return String(localized: "近90天")
        case .all: return String(localized: "全部")
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

// MARK: - 图标资产识别

/// 实体图标名是否为 Asset Catalog 自绘资产（finance_ / income_ / cat_ / habit_ 前缀）。
/// 定义在本文件而非 UnifiedIconCatalog：Habit.swift 随本文件一同被 HoloWidgets 扩展编译，
/// 而统一图标目录只在主 App target；UnifiedIconCatalog.isAssetIcon 转发到这里，保持单一事实源。
nonisolated enum EntityIconAsset {
    static func isAsset(_ name: String) -> Bool {
        name.hasPrefix("finance_") || name.hasPrefix("income_") || name.hasPrefix("cat_") || name.hasPrefix("habit_")
    }
}

// MARK: - 预设颜色

/// 习惯预设颜色列表
struct HabitColorPresets {
    /// Hex 颜色值列表
    ///
    /// 2026-10-06 换「暖化 12 色」（温润纸感方案）：每个色预钳到白字对比 ≥3:1 的
    /// 安全区间，色相顺序对齐图表色板。只影响新建/改选；存量习惯色由
    /// `Color.holoHabitSurface(_:scheme:)` 在完成态渲染层钳制治理。
    static let colors: [String] = [
        "#3B76C9",  // 蓝
        "#D9662C",  // 橙
        "#2FA360",  // 绿
        "#D64545",  // 红
        "#8063CE",  // 紫
        "#1F9E9E",  // 青
        "#C94F86",  // 粉
        "#A87B0F",  // 金
        "#5A67C7",  // 靛
        "#6E8F26",  // 黄绿
        "#CE4A6B",  // 玫红
        "#2E8FB8"   // 天蓝
    ]
    
    /// 将 Hex 转换为 Color
    static func color(from hex: String) -> Color {
        Color(hex: hex)
    }
}
