//
//  Budget.swift
//  Holo
//
//  预算实体类
//

import Foundation
import CoreData

/// 预算实体
@objc(Budget)
public class Budget: NSManagedObject {

    // MARK: - Properties

    @NSManaged public var id: UUID
    @NSManaged public var accountId: UUID
    @NSManaged public var categoryId: UUID?
    @NSManaged public var amount: NSDecimalNumber
    @NSManaged public var period: String
    @NSManaged public var startDate: Date
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Computed Properties

    /// 预算周期枚举
    var budgetPeriod: BudgetPeriod {
        BudgetPeriod(rawValue: period) ?? .month
    }

    /// 是否为总预算（无分类绑定）
    var isTotalBudget: Bool {
        categoryId == nil
    }

    // MARK: - Methods

    /// 删除预算
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Concurrency
extension Budget: @unchecked Sendable {}
