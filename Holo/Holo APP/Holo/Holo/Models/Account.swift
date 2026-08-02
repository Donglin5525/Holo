//
//  Account.swift
//  Holo
//
//  账户实体类
//

import Foundation
import CoreData
import SwiftUI

/// 账户实体
@objc(Account)
public class Account: NSManagedObject {

    // MARK: - Properties

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var type: String
    @NSManaged public var isDefault: Bool
    @NSManaged public var initialBalance: NSDecimalNumber
    @NSManaged public var customIcon: String
    @NSManaged public var color: String
    @NSManaged public var sortOrder: Int16
    @NSManaged public var isArchived: Bool
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // 信用卡专属字段（非信用卡账户保持默认值 0）
    /// 账单日（每月几号出账单，1-31，0 表示未设置）
    @NSManaged public var billingDay: Int16
    /// 还款日（每月几号最后还款，1-31，0 表示未设置）
    @NSManaged public var dueDay: Int16
    /// 信用额度（信用卡总额度，0 表示未设置）
    @NSManaged public var creditLimit: NSDecimalNumber

    /// 反向关系：该账户下的所有交易（Core Data 自动维护）
    @NSManaged public var transactions: Set<Transaction>?

    // MARK: - Computed Properties

    /// 账户类型枚举
    /// 兼容历史值：旧版 "card"/"debitCard" 统一归入 .bank（储蓄卡），避免类型缺失时 fallback 到现金
    var accountType: AccountType {
        if type == "card" || type == "debitCard" {
            return .bank
        }
        return AccountType(rawValue: type) ?? .cash
    }

    /// 账户图标（优先使用自定义图标，空则回退到 AccountType 默认）
    var icon: String {
        customIcon.isEmpty ? accountType.icon : customIcon
    }

    /// SwiftUI 颜色（color 为空时回退到 slate 灰蓝；非法 hex 由 Color(hex:) 兜底为红色以暴露问题）
    var swiftUIColor: Color {
        Color(hex: color.isEmpty ? "#64748B" : color)
    }

    // MARK: - 信用卡计算属性

    /// 信用额度的 Decimal 形式
    var creditLimitDecimal: Decimal { creditLimit as Decimal }

    /// 是否配置了账单日/还款日
    var hasBillingCycle: Bool { billingDay > 0 && dueDay > 0 }

    /// 信用卡可用额度 = 信用额度 + 当前余额（余额为负代表欠款，会扣减可用额度）
    /// 非信用卡或未设额度时返回 nil。
    func availableCredit(balance: Decimal) -> Decimal? {
        guard accountType.isCreditCard, creditLimitDecimal > 0 else { return nil }
        return creditLimitDecimal + balance
    }

    // MARK: - Methods

    /// 删除账户
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Concurrency
/// 允许在并发闭包中安全捕获 Account（当前场景下使用）
extension Account: @unchecked Sendable {}
