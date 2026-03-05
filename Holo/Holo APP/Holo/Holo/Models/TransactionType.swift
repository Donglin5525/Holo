//
//  TransactionType.swift
//  Holo
//
//  交易类型枚举定义
//

import Foundation

/// 交易类型枚举
enum TransactionType: String {
    case income = "income"      // 收入
    case expense = "expense"    // 支出
    
    /// 显示名称
    var displayName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        }
    }
    
    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .income: return "arrow.down.circle.fill"
        case .expense: return "arrow.up.circle.fill"
        }
    }
}