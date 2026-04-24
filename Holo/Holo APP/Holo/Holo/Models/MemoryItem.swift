//
//  MemoryItem.swift
//  Holo
//
//  记忆长廊统一数据模型
//  将交易、习惯记录、任务等不同类型的数据统一为 MemoryItem 进行展示
//

import Foundation
import SwiftUI
import CoreData

// MARK: - MemoryItemType

/// 记忆类型
enum MemoryItemType: String, CaseIterable {
    case transaction = "transaction"
    case habitRecord = "habitRecord"
    case task = "task"
    case thought = "thought"

    var displayName: String {
        switch self {
        case .transaction: return "记账"
        case .habitRecord: return "习惯"
        case .task: return "待办"
        case .thought: return "观点"
        }
    }

    var icon: String {
        switch self {
        case .transaction: return "creditcard.fill"
        case .habitRecord: return "checkmark.circle.fill"
        case .task: return "checklist"
        case .thought: return "lightbulb.fill"
        }
    }
}

// MARK: - MemoryModuleFilter

/// 模块筛选类型
enum MemoryModuleFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case transaction = "transaction"
    case habitRecord = "habitRecord"
    case task = "task"
    case thought = "thought"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .transaction: return "记账"
        case .habitRecord: return "习惯"
        case .task: return "待办"
        case .thought: return "观点"
        }
    }
}

// MARK: - MemoryItem

/// 统一的记忆条目模型
struct MemoryItem: Identifiable, Equatable {
    let id: UUID
    let type: MemoryItemType
    let date: Date
    let title: String
    let subtitle: String?
    let icon: String
    let colorHex: String
    let amount: Decimal?
    let note: String?
    let createdAt: Date

    // 原始数据的引用 ID（用于跳转到详情页）
    let sourceId: UUID

    // Equatable
    static func == (lhs: MemoryItem, rhs: MemoryItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.date == rhs.date &&
        lhs.title == rhs.title
    }
}

// MARK: - MemoryItem Extensions

extension MemoryItem {
    /// 从交易记录创建 MemoryItem
    static func from(transaction: Transaction) -> MemoryItem {
        let isExpense = transaction.transactionType == .expense
        let sign = isExpense ? "-" : "+"

        return MemoryItem(
            id: transaction.id,
            type: .transaction,
            date: transaction.date,
            title: transaction.category.name,
            subtitle: transaction.note ?? transaction.account.name,
            icon: transaction.category.icon,
            colorHex: transaction.category.color,
            amount: transaction.amount.decimalValue,
            note: transaction.note,
            createdAt: transaction.createdAt,
            sourceId: transaction.id
        )
    }

    /// 从习惯记录创建 MemoryItem
    static func from(habitRecord: HabitRecord, habit: Habit) -> MemoryItem {
        var subtitle: String?
        if habit.isNumericType, let value = habitRecord.valueDouble {
            subtitle = "\(value)\(habit.unit ?? "")"
        } else if habit.isCheckInType {
            subtitle = habitRecord.isCompleted ? "已完成" : "未完成"
        }

        return MemoryItem(
            id: habitRecord.id,
            type: .habitRecord,
            date: habitRecord.date,
            title: habit.name,
            subtitle: subtitle,
            icon: habit.icon,
            colorHex: habit.color,
            amount: nil,
            note: habitRecord.note,
            createdAt: habitRecord.createdAt,
            sourceId: habit.id
        )
    }

    /// 从任务创建 MemoryItem（已完成或已过期的任务）
    static func from(task: TodoTask) -> MemoryItem {
        var subtitle: String?
        if task.completed {
            subtitle = "已完成"
        } else if let dueDate = task.dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            subtitle = formatter.string(from: dueDate)
        }

        return MemoryItem(
            id: task.id,
            type: .task,
            date: task.completedAt ?? task.dueDate ?? task.createdAt,
            title: task.title,
            subtitle: subtitle,
            icon: "checklist",
            colorHex: "#6366F1", // 默认靛蓝色
            amount: nil,
            note: task.desc,
            createdAt: task.createdAt,
            sourceId: task.id
        )
    }

    /// 从观点创建 MemoryItem
    static func from(thought: Thought) -> MemoryItem {
        let title = thought.previewText.isEmpty ? "未命名观点" : thought.previewText
        let subtitle = thought.moodType?.displayName

        return MemoryItem(
            id: thought.id,
            type: .thought,
            date: thought.createdAt,
            title: title,
            subtitle: subtitle,
            icon: "lightbulb.fill",
            colorHex: "#F59E0B",
            amount: nil,
            note: thought.content,
            createdAt: thought.createdAt,
            sourceId: thought.id
        )
    }
}

// MARK: - Computed Properties

extension MemoryItem {
    /// 解析颜色
    var color: Color {
        Color(hex: colorHex) ?? .holoPrimary
    }

    /// 格式化日期（相对时间）
    var formattedRelativeDate: String {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: now)

        let components = calendar.dateComponents([.day], from: dayStart, to: nowStart)

        if let days = components.day {
            if days == 0 {
                return "今天"
            } else if days == 1 {
                return "昨天"
            } else if days < 7 {
                return "\(days)天前"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd"
                return formatter.string(from: date)
            }
        }

        return ""
    }

    /// 格式化时间
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 格式化完整日期时间
    var formattedFullDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 格式化金额（仅交易类型）
    var formattedAmount: String? {
        guard let amount = amount else { return nil }
        let formatter = NumberFormatter.currency
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }
}

// MARK: - MemoryItemSection

/// 记忆条目分组（按日期）
struct MemoryItemSection: Identifiable {
    let date: Date
    var items: [MemoryItem]

    var id: Date { date }

    /// 格式化日期标题
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter.string(from: date)
    }

    /// 是否是今天
    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    /// 是否是昨天
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(date)
    }

    /// 显示标题（今天/昨天/具体日期）
    var displayTitle: String {
        if isToday {
            return "今天"
        } else if isYesterday {
            return "昨天"
        } else {
            return formattedDate
        }
    }
}
