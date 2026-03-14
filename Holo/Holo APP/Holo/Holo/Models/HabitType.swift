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

// MARK: - 预设图标分类

/// 习惯图标分类定义
/// 每个分类包含图标名、显示名称和描述
struct HabitIconCategory: Identifiable {
    let id = UUID()
    let name: String           // 分类名称
    let icon: String           // 分类图标（用于分类标题）
    let items: [IconItem]      // 该分类下的图标列表
}

/// 单个图标项
struct IconItem: Identifiable {
    let id = UUID()
    let name: String           // 图标名称（SF Symbol 或 Asset 名称）
    let label: String          // 中文标签
    let isCustom: Bool         // 是否为自定义图标（Asset Catalog）
    
    init(name: String, label: String, isCustom: Bool = false) {
        self.name = name
        self.label = label
        self.isCustom = isCustom
    }
}

// MARK: - 预设图标

/// 习惯预设图标列表（按分类组织）
struct HabitIconPresets {
    
    // MARK: - 图标分类数据
    
    /// 所有图标分类（用于分类展示）
    static let categories: [HabitIconCategory] = [
        // ━━━━━━━━━━ 1. 运动健身 ━━━━━━━━━━
        HabitIconCategory(name: "运动健身", icon: "figure.run", items: [
            IconItem(name: "figure.walk", label: "散步"),
            IconItem(name: "figure.run", label: "跑步"),
            IconItem(name: "dumbbell.fill", label: "健身"),
            IconItem(name: "figure.yoga", label: "瑜伽"),
            IconItem(name: "figure.pool.swim", label: "游泳"),
            IconItem(name: "bicycle", label: "骑行"),
            IconItem(name: "figure.jumprope", label: "跳绳"),
            IconItem(name: "figure.step.training", label: "步数"),
        ]),
        
        // ━━━━━━━━━━ 2. 健康生活 ━━━━━━━━━━
        HabitIconCategory(name: "健康生活", icon: "heart.fill", items: [
            IconItem(name: "drop.fill", label: "喝水"),
            IconItem(name: "bed.double.fill", label: "睡眠"),
            IconItem(name: "moon.fill", label: "早睡"),
            IconItem(name: "sun.max.fill", label: "早起"),
            IconItem(name: "brain.head.profile", label: "冥想"),
            IconItem(name: "heart.fill", label: "心脏"),
            IconItem(name: "pill.fill", label: "服药"),
            IconItem(name: "cross.case.fill", label: "医疗"),
            IconItem(name: "scalemass.fill", label: "体重"),
            IconItem(name: "bandage.fill", label: "护理"),
        ]),
        
        // ━━━━━━━━━━ 3. 学习成长 ━━━━━━━━━━
        HabitIconCategory(name: "学习成长", icon: "book.fill", items: [
            IconItem(name: "book.fill", label: "阅读"),
            IconItem(name: "pencil", label: "写作"),
            IconItem(name: "rectangle.and.pencil.and.ellipsis", label: "笔记"),
            IconItem(name: "character.book.closed", label: "外语"),
            IconItem(name: "graduationcap.fill", label: "课程"),
            IconItem(name: "lightbulb.fill", label: "学习"),
            IconItem(name: "puzzlepiece.fill", label: "技能"),
            IconItem(name: "doc.text.fill", label: "文档"),
        ]),
        
        // ━━━━━━━━━━ 4. 自我提升 ━━━━━━━━━━
        HabitIconCategory(name: "自我提升", icon: "sparkles", items: [
            IconItem(name: "sparkles", label: "复盘"),
            IconItem(name: "calendar.badge.clock", label: "计划"),
            IconItem(name: "hands.sparkles.fill", label: "感恩"),
            IconItem(name: "target", label: "目标"),
            IconItem(name: "clock.fill", label: "专注"),
            IconItem(name: "flame.fill", label: "坚持"),
            IconItem(name: "star.fill", label: "成就"),
            IconItem(name: "arrow.up.circle.fill", label: "进步"),
        ]),
        
        // ━━━━━━━━━━ 5. 饮食营养 ━━━━━━━━━━
        HabitIconCategory(name: "饮食营养", icon: "fork.knife", items: [
            IconItem(name: "fork.knife", label: "饮食"),
            IconItem(name: "cup.and.saucer.fill", label: "咖啡"),
            IconItem(name: "leaf.fill", label: "蔬果"),
            IconItem(name: "takeoutbag.and.cup.and.straw.fill", label: "饮品"),
            IconItem(name: "birthday.cake.fill", label: "甜点"),
            IconItem(name: "sun.horizon.fill", label: "早餐"),
        ]),
        
        // ━━━━━━━━━━ 6. 财务理财 ━━━━━━━━━━
        HabitIconCategory(name: "财务理财", icon: "dollarsign.circle.fill", items: [
            IconItem(name: "list.clipboard.fill", label: "记账"),
            IconItem(name: "banknote.fill", label: "存钱"),
            IconItem(name: "chart.line.uptrend.xyaxis", label: "投资"),
            IconItem(name: "creditcard.fill", label: "预算"),
            IconItem(name: "dollarsign.circle.fill", label: "储蓄"),
        ]),
        
        // ━━━━━━━━━━ 7. 日常习惯 ━━━━━━━━━━
        HabitIconCategory(name: "日常习惯", icon: "house.fill", items: [
            IconItem(name: "house.fill", label: "家务"),
            IconItem(name: "bed.double.circle.fill", label: "整理"),
            IconItem(name: "trash.fill", label: "清洁"),
            IconItem(name: "face.smiling.fill", label: "护肤"),
            IconItem(name: "mouth.fill", label: "刷牙"),
            IconItem(name: "camera.fill", label: "记录"),
            IconItem(name: "phone.fill", label: "联系"),
        ]),
        
        // ━━━━━━━━━━ 8. 戒除/减少 ━━━━━━━━━━
        HabitIconCategory(name: "戒除/减少", icon: "xmark.shield.fill", items: [
            IconItem(name: "habit_nosmoking", label: "戒烟", isCustom: true),
            IconItem(name: "wineglass.fill", label: "戒酒"),
            IconItem(name: "iphone.slash", label: "少玩手机"),
            IconItem(name: "moon.zzz.fill", label: "少熬夜"),
            IconItem(name: "xmark.shield.fill", label: "戒除"),
            IconItem(name: "hand.thumbsdown.fill", label: "减少"),
        ]),
        
        // ━━━━━━━━━━ 9. 其他 ━━━━━━━━━━
        HabitIconCategory(name: "其他", icon: "checkmark.circle", items: [
            IconItem(name: "checkmark.circle", label: "打卡"),
            IconItem(name: "circle.dashed", label: "待办"),
            IconItem(name: "tag.fill", label: "标签"),
            IconItem(name: "guitars.fill", label: "音乐"),
            IconItem(name: "gamecontroller.fill", label: "游戏"),
            IconItem(name: "paintbrush.fill", label: "绘画"),
        ]),
    ]
    
    // MARK: - 扁平化图标列表（兼容旧版）
    
    /// 所有图标名称列表（扁平化，用于简单网格展示）
    static let icons: [String] = categories.flatMap { $0.items.map { $0.name } }
    
    /// 所有图标项列表（带标签）
    static let allItems: [IconItem] = categories.flatMap { $0.items }
    
    /// 根据图标名获取中文标签
    static func label(for iconName: String) -> String {
        allItems.first { $0.name == iconName }?.label ?? iconName
    }
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
