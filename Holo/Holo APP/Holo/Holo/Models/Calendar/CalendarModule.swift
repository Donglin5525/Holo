//
//  CalendarModule.swift
//  Holo
//
//  日历视图模块类型（记账/习惯/待办/想法/健康）
//

import SwiftUI

/// 日历视图聚合的 5 个模块
enum CalendarModule: String, CaseIterable, Identifiable, Hashable {
    case finance
    case habit
    case todo
    case thought
    case health

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .finance: return "记账"
        case .habit:   return "习惯"
        case .todo:    return "待办"
        case .thought: return "想法"
        case .health:  return "健康"
        }
    }

    /// 模块代表色（与 Holo 设计系统一致）
    /// 说明：项目里记账/待办原都占橙，日历分色场景会撞，故待办改靛蓝（取自记账分类色「购物」）
    var color: Color {
        switch self {
        case .finance: return .holoPrimary   // 橙 #F46D38
        case .habit:   return .holoSuccess   // 绿 #22C55E
        case .todo:    return .holoChart9    // 靛 #6366F1
        case .thought: return .holoChart7    // 粉 #EC4899
        case .health:  return .holoChart1    // 蓝 #3B82F6
        }
    }

    /// SF Symbol 图标
    /// 前 4 个已在 MemoryItemType 验证存在；heart.fill 为标准 SF Symbol
    var iconName: String {
        switch self {
        case .finance: return "creditcard.fill"
        case .habit:   return "checkmark.circle.fill"
        case .todo:    return "checklist"
        case .thought: return "lightbulb.fill"
        case .health:  return "heart.fill"
        }
    }
}
