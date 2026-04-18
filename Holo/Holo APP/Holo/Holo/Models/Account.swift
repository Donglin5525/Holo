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

    // MARK: - Computed Properties

    /// 账户类型枚举
    var accountType: AccountType {
        AccountType(rawValue: type) ?? .cash
    }

    /// 账户图标（优先使用自定义图标，空则回退到 AccountType 默认）
    var icon: String {
        customIcon.isEmpty ? accountType.icon : customIcon
    }

    /// SwiftUI 颜色
    var swiftUIColor: Color {
        Color(hex: color) ?? Color(hex: "#64748B") ?? .gray
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