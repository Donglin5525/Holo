//
//  TaskSortOption.swift
//  Holo
//
//  任务列表排序方式 —— 每种排序自带分组策略与直觉默认方向
//  方案与交互原型见 docs/design-prototypes/task-list-sorting-prototype.html
//

import SwiftUI

// MARK: - 排序方式

/// 任务列表排序方式
enum TaskSortOption: String, CaseIterable, Identifiable {
    /// 截止时间（时间分组，现版本默认行为）
    case due
    /// 优先级（优先级四分组，同级内按截止时间细排）
    case priority
    /// 创建时间（平铺不分组）
    case created
    /// 完成时间（周分组，仅已完成页可选）
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .due: return "截止时间"
        case .priority: return "优先级"
        case .created: return "创建时间"
        case .completed: return "完成时间"
        }
    }

    var icon: String {
        switch self {
        case .due: return "calendar"
        case .priority: return "flag"
        case .created: return "plus.circle"
        case .completed: return "checkmark.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .due: return "按任务什么时候到期排列"
        case .priority: return "紧急 / 高 / 中 / 低，同级内按截止时间"
        case .created: return "按任务是什么时候创建的排列"
        case .completed: return "按任务是什么时候完成的排列"
        }
    }

    /// 直觉默认方向是否为数值升序（截止=早在前；优先级/创建/完成=高的/新的/最近的在前）
    var defaultAscending: Bool {
        switch self {
        case .due: return true
        case .priority, .created, .completed: return false
        }
    }

    /// 方向文案说人话，不暴露「升序/降序」术语
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .due: return ascending ? "早 → 晚" : "晚 → 早"
        case .priority: return ascending ? "低 → 高" : "高 → 低"
        case .created: return ascending ? "旧 → 新" : "新 → 旧"
        case .completed: return ascending ? "最早在前" : "最近在前"
        }
    }

    // MARK: 分组策略

    enum Grouping {
        /// 时间分组（过期/今天/明天/本周/稍后/未安排）
        case time
        /// 优先级四分组
        case priority
        /// 平铺不分组
        case flat
        /// 按周分组（已完成页）
        case week
    }

    var grouping: Grouping {
        switch self {
        case .due: return .time
        case .priority: return .priority
        case .created: return .flat
        case .completed: return .week
        }
    }

    /// 当前筛选下是否可选（完成时间只对已完成页有意义）
    func isAvailable(for filter: TaskFilterType) -> Bool {
        if self == .completed { return filter == .completed }
        return true
    }

    // MARK: - 排序比较器

    /// sorted(by:) 谓词：返回 true 表示 a 排在 b 前。
    /// 空值（无截止/完成时间）无论方向恒沉底；排序值并列由次级排序兜底，保证列表顺序稳定。
    func areInOrder(_ a: TodoTask, _ b: TodoTask, ascending: Bool) -> Bool {
        switch self {
        case .due:
            if let result = Self.compareDates(a.dueDate, b.dueDate, ascending: ascending) {
                return result
            }
        case .priority:
            if a.taskPriority.rawValue != b.taskPriority.rawValue {
                return ascending
                    ? a.taskPriority.rawValue < b.taskPriority.rawValue
                    : a.taskPriority.rawValue > b.taskPriority.rawValue
            }
            // 同优先级：组内按截止时间早→晚，无日期沉底
            if let result = Self.compareDates(a.dueDate, b.dueDate, ascending: true) {
                return result
            }
        case .created:
            if a.createdAt != b.createdAt {
                return ascending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
            }
        case .completed:
            if let x = a.completedAt, let y = b.completedAt, x != y {
                return ascending ? x < y : x > y
            }
        }
        return Self.tiebreak(a, b)
    }

    /// 可空日期比较：空值恒沉底（不随方向翻转到顶部）；双空或相等返回 nil 交给次级
    private static func compareDates(_ a: Date?, _ b: Date?, ascending: Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?):
            if x == y { return nil }
            return ascending ? x < y : x > y
        }
    }

    /// 次级排序：创建时间新→旧；仍相同返回 false（保持稳定排序）
    private static func tiebreak(_ a: TodoTask, _ b: TodoTask) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return false
    }
}
