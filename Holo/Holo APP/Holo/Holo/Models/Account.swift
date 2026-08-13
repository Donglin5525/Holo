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
    /// 信用卡账单日（1-31），仅信用卡
    @NSManaged public var billingDay: NSNumber?
    /// 信用卡还款日（1-31），仅信用卡
    @NSManaged public var dueDay: NSNumber?
    /// 信用卡额度，仅信用卡（可选）
    @NSManaged public var creditLimit: NSDecimalNumber?
    /// 导入批次 ID：标记由某次导入自动创建的账户，撤回时据此判断可否删除
    @NSManaged public var importBatchId: UUID?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    /// 反向关系：该账户下的所有交易（Core Data 自动维护）
    @NSManaged public var transactions: Set<Transaction>?

    // MARK: - Computed Properties

    /// 账户类型枚举
    var accountType: AccountType {
        AccountType(rawValue: type) ?? .cash
    }

    /// 账单日（Int?，1-31），非信用卡或未设置时为 nil
    var billingDayInt: Int? {
        guard let value = billingDay?.intValue else { return nil }
        return (1...31).contains(value) ? value : nil
    }

    /// 还款日（Int?，1-31），非信用卡或未设置时为 nil
    var dueDayInt: Int? {
        guard let value = dueDay?.intValue else { return nil }
        return (1...31).contains(value) ? value : nil
    }

    /// 信用卡额度（Decimal），未设置时为 nil
    var creditLimitDecimal: Decimal? {
        creditLimit?.decimalValue
    }

    /// 是否已配置账单周期信息
    var hasBillingCycle: Bool {
        billingDayInt != nil
    }

    /// 账户图标（优先使用自定义图标，空则回退到 AccountType 默认）
    var icon: String {
        customIcon.isEmpty ? accountType.icon : customIcon
    }

    /// SwiftUI 颜色（color 为空时回退到 slate 灰蓝；非法 hex 由 Color(hex:) 兜底为红色以暴露问题）
    var swiftUIColor: Color {
        Color(hex: color.isEmpty ? "#64748B" : color)
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