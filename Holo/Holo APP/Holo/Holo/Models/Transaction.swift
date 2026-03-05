//
//  Transaction.swift
//  Holo
//
//  交易记录实体类
//

import Foundation
import CoreData

/// 交易记录实体
@objc(Transaction)
public class Transaction: NSManagedObject {
    
    // MARK: - Properties
    
    @NSManaged public var id: UUID
    /// 金额（使用 NSDecimalNumber 以兼容 Core Data 的 decimal 属性）
    @NSManaged public var amount: NSDecimalNumber
    @NSManaged public var type: String
    @NSManaged public var date: Date
    @NSManaged public var note: String?
    @NSManaged public var tags: [String]?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var category: Category
    @NSManaged public var account: Account
    
    // MARK: - Computed Properties
    
    /// 交易类型枚举
    var transactionType: TransactionType {
        TransactionType(rawValue: type) ?? .expense
    }
    
    /// 格式化金额（带符号）
    public var formattedAmountWithSign: String {
        let formatter = NumberFormatter.currency
        switch transactionType {
        case .income:
            return "+\(formatter.string(from: amount) ?? "")"
        case .expense:
            return "-\(formatter.string(from: amount) ?? "")"
        }
    }
    
    /// 格式化金额（不带符号）
    public var formattedAmount: String {
        NumberFormatter.currency.string(from: amount) ?? ""
    }
    
    /// 金额的 Decimal 形式（便于计算）
    public var amountAsDecimal: Decimal {
        amount as Decimal
    }
    
    // MARK: - Methods
    
    /// 删除交易
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Concurrency
/// 允许在并发闭包中安全捕获 Transaction（仅在当前简单场景下使用）
extension Transaction: @unchecked Sendable {}