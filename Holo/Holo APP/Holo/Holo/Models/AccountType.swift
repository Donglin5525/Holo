//
//  AccountType.swift
//  Holo
//
//  账户类型枚举定义
//

import Foundation

/// 账户类型枚举
enum AccountType: String, CaseIterable {
    case cash = "cash"                  // 现金
    case digital = "digital"            // 数字支付（微信/支付宝）
    case bank = "bank"                  // 储蓄卡（银行储蓄账户）
    case debitCard = "debitCard"        // 储蓄卡/借记卡
    case creditCard = "creditCard"      // 信用卡
    case other = "other"                // 其他

    /// 显示名称
    var displayName: String {
        switch self {
        case .cash: return "现金"
        case .digital: return "数字钱包"
        case .bank: return "储蓄卡"
        case .debitCard: return "储蓄卡"
        case .creditCard: return "信用卡"
        case .other: return "其他"
        }
    }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .cash: return "dollarsign"
        case .digital: return "wallet.pass"
        case .bank: return "building.columns"
        case .debitCard: return "creditcard"
        case .creditCard: return "creditcard.fill"
        case .other: return "ellipsis.circle"
        }
    }

    /// 默认颜色 hex
    var defaultColor: String {
        switch self {
        case .cash: return "#22C55E"
        case .digital: return "#1677FF"
        case .bank: return "#6366F1"
        case .debitCard: return "#6366F1"
        case .creditCard: return "#F59E0B"
        case .other: return "#64748B"
        }
    }

    /// 是否为信用卡（拥有账单日/还款日/额度等专属概念）
    var isCreditCard: Bool { self == .creditCard }

    /// 显式排序权重，列表分组按此排序而非 rawValue 字符串
    var sortOrder: Int {
        switch self {
        case .cash: return 0
        case .digital: return 1
        case .bank: return 2
        case .debitCard: return 3
        case .creditCard: return 4
        case .other: return 5
        }
    }
}
