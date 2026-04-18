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
    case card = "card"              // 银行卡/信用卡
    case other = "other"            // 其他

    /// 显示名称
    var displayName: String {
        switch self {
        case .cash: return "现金"
        case .digital: return "数字钱包"
        case .bank: return "储蓄卡"
        case .card: return "银行卡/信用卡"
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
        case .other: return "ellipsis.circle"
        }
    }

    /// 默认颜色 hex
    var defaultColor: String {
        switch self {
        case .cash: return "#22C55E"
        case .digital: return "#1677FF"
        case .bank: return "#6366F1"
        case .card: return "#F59E0B"
        case .other: return "#64748B"
        }
    }
}
