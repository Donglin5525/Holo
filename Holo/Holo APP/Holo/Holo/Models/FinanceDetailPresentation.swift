//
//  FinanceDetailPresentation.swift
//  Holo
//
//  财务明细页的稳定排序规则
//

import Foundation

/// 财务明细排序方式。
/// 时间排序保持日期分组；金额排序按全局金额展示，避免“只在每天内部排序”的误导。
nonisolated enum FinanceDetailSortOrder: String, CaseIterable, Identifiable {
    case timeDescending
    case timeAscending
    case amountDescending
    case amountAscending

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .timeDescending: return "时间：从新到旧"
        case .timeAscending: return "时间：从旧到新"
        case .amountDescending: return "金额：从高到低"
        case .amountAscending: return "金额：从低到高"
        }
    }

    var compactTitle: String {
        switch self {
        case .timeDescending: return "时间↓"
        case .timeAscending: return "时间↑"
        case .amountDescending: return "金额↓"
        case .amountAscending: return "金额↑"
        }
    }

    var systemImage: String {
        switch self {
        case .timeDescending, .timeAscending:
            return "calendar"
        case .amountDescending, .amountAscending:
            return "yensign"
        }
    }

    var groupsByDay: Bool {
        switch self {
        case .timeDescending, .timeAscending:
            return true
        case .amountDescending, .amountAscending:
            return false
        }
    }

    /// 趋势图按日期导航时必须回到时间分组，否则金额平铺列表没有稳定的日期锚点。
    var orderForChartNavigation: FinanceDetailSortOrder {
        groupsByDay ? self : .timeDescending
    }

    func areInIncreasingOrder(
        _ lhs: FinanceDetailSortValue,
        _ rhs: FinanceDetailSortValue
    ) -> Bool {
        switch self {
        case .timeDescending:
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        case .timeAscending:
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.amount != rhs.amount { return lhs.amount < rhs.amount }
        case .amountDescending:
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
        case .amountAscending:
            if lhs.amount != rhs.amount { return lhs.amount < rhs.amount }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// 排序只依赖不可变值，便于独立验证，也避免比较过程中反复访问 Core Data 对象。
nonisolated struct FinanceDetailSortValue: Equatable {
    let id: UUID
    let date: Date
    let amount: Decimal
}
