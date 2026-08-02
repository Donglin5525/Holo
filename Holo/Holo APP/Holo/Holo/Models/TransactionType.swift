//
//  TransactionType.swift
//  Holo
//
//  交易类型枚举定义
//

import Foundation

/// 交易类型枚举
enum TransactionType: String, Codable, Sendable, Hashable {
    case income = "income"      // 收入
    case expense = "expense"    // 支出
    case transfer = "transfer"  // 转账（只动余额，不计入收支统计）

    /// 显示名称
    var displayName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        case .transfer: return "转账"
        }
    }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .income: return "arrow.down.circle.fill"
        case .expense: return "arrow.up.circle.fill"
        case .transfer: return "arrow.right.arrow.left.circle.fill"
        }
    }

    /// 是否只影响余额、不计入收支统计（转账一进一出，净值不变但不应虚增收支）
    var affectsBalanceOnly: Bool { self == .transfer }
}
