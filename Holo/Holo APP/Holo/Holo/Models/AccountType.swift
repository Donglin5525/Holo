//
//  AccountType.swift
//  Holo
//
//  账户类型枚举定义
//

import Foundation

/// 账户类型枚举
enum AccountType: String, CaseIterable {
    case cash = "cash"              // 现金
    case digital = "digital"        // 数字支付（微信/支付宝）
    case bank = "bank"              // 储蓄卡
    case card = "card"              // 储蓄卡/借记卡
    case creditCard = "creditCard"  // 信用卡
    case other = "other"            // 其他

    /// 显示名称
    var displayName: String {
        switch self {
        case .cash: return "现金"
        case .digital: return "数字钱包"
        case .bank: return "储蓄卡"
        case .card: return "储蓄卡"
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
        case .card: return "creditcard"
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
        case .card: return "#6366F1"
        case .creditCard: return "#F59E0B"
        case .other: return "#64748B"
        }
    }

    /// 在账户列表里的排序权重（数字越小越靠前）
    /// AccountListView 用这个排序，避免按 rawValue 字母序导致 creditCard 位置错乱
    var sortOrder: Int {
        switch self {
        case .cash: return 0
        case .digital: return 1
        case .bank: return 2
        case .card: return 3
        case .creditCard: return 4
        case .other: return 5
        }
    }

    /// 是否为信用卡类型（有账单周期、额度等专属属性）
    var isCreditCard: Bool {
        self == .creditCard
    }
}
