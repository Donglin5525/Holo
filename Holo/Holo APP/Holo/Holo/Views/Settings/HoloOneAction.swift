//
//  HoloOneAction.swift
//  Holo
//
//  Holo One 快捷动作枚举
//  定义底部导航栏中心按钮可配置的 5 种快捷入口
//

import SwiftUI

/// Holo One 快捷动作类型
/// 用户可在设置中选择中心按钮触发的动作
enum HoloOneAction: String, CaseIterable {
    /// 快速记账
    case addTransaction = "addTransaction"
    /// 新建待办
    case addTask = "addTask"
    /// 习惯打卡
    case habitCheckIn = "habitCheckIn"
    /// 记录想法
    case recordThought = "recordThought"
    /// AI 对话
    case aiChat = "aiChat"

    // MARK: - 显示信息

    /// 中文显示名称
    var displayName: String {
        switch self {
        case .addTransaction: return "快速记账"
        case .addTask: return "新建待办"
        case .habitCheckIn: return "习惯打卡"
        case .recordThought: return "记录想法"
        case .aiChat: return "AI 对话"
        }
    }

    /// SF Symbol 图标名
    var iconName: String {
        switch self {
        case .addTransaction: return "yensign.circle.fill"
        case .addTask: return "checklist"
        case .habitCheckIn: return "checkmark.circle.fill"
        case .recordThought: return "lightbulb.fill"
        case .aiChat: return "text.bubble.fill"
        }
    }

    /// 功能描述
    var description: String {
        switch self {
        case .addTransaction: return "快速打开记账页面"
        case .addTask: return "快速打开新建待办页面"
        case .habitCheckIn: return "选择一个习惯完成打卡"
        case .recordThought: return "快速记录一条想法"
        case .aiChat: return "快速进入 AI 对话界面"
        }
    }

    /// 图标颜色
    var iconColor: Color {
        switch self {
        case .addTransaction: return .holoPrimary
        case .addTask: return .blue
        case .habitCheckIn: return .green
        case .recordThought: return .yellow
        case .aiChat: return .purple
        }
    }
}
