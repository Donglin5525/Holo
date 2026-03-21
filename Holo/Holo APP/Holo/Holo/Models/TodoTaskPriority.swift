//
//  TodoTaskPriority.swift
//  Holo
//
//  任务优先级和状态枚举
//

import Foundation

// MARK: - TaskStatus

/// 任务状态
enum TaskStatus: String, Codable, CaseIterable {
    case todo = "todo"           // 待办
    case inProgress = "inProgress" // 进行中
    case completed = "completed"   // 已完成

    var displayTitle: String {
        switch self {
        case .todo: return "待办"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        }
    }

    var iconName: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

// MARK: - TaskPriority

/// 任务优先级
enum TaskPriority: Int16, Codable, CaseIterable {
    case urgent = 3   // 十分紧急（红色）
    case high = 2     // 高（橙色）
    case medium = 1   // 中（黄色）
    case low = 0      // 低（灰色）

    var displayTitle: String {
        switch self {
        case .urgent: return "十分紧急"
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    var colorName: String {
        switch self {
        case .urgent: return "red"
        case .high: return "orange"
        case .medium: return "yellow"
        case .low: return "gray"
        }
    }

    var iconName: String {
        switch self {
        case .urgent: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.circle.fill"
        case .medium: return "exclamationmark.circle"
        case .low: return "circle"
        }
    }

    /// 所有优先级的数组（按优先级降序排列）
    static let allCasesSorted: [TaskPriority] = [.urgent, .high, .medium, .low]
}

// MARK: - TaskPriority Color Extension

import SwiftUI

extension TaskPriority {
    var color: Color {
        switch self {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .gray
        }
    }
}
