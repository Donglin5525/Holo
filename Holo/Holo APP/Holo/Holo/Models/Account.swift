//
//  Account.swift
//  Holo
//
//  账户实体类
//

import Foundation
import CoreData

/// 账户实体
@objc(Account)
public class Account: NSManagedObject {
    
    // MARK: - Properties
    
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var type: String
    @NSManaged public var isDefault: Bool
    
    // MARK: - Computed Properties
    
    /// 账户类型枚举
    var accountType: AccountType {
        AccountType(rawValue: type) ?? .cash
    }
    
    /// 账户图标
    var icon: String {
        accountType.icon
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