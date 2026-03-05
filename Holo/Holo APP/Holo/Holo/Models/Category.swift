//
//  Category.swift
//  Holo
//
//  分类实体类
//

import Foundation
import CoreData
import SwiftUI

/// 分类实体
@objc(Category)
public class Category: NSManagedObject {
    
    // MARK: - Properties
    
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var icon: String
    @NSManaged public var color: String
    @NSManaged public var type: String
    @NSManaged public var isDefault: Bool
    @NSManaged public var sortOrder: Int16
    
    // MARK: - Computed Properties
    
    /// SwiftUI 颜色
    public var swiftUIColor: Color {
        Color(hex: color) ?? .holoPrimary
    }
    
    /// 交易类型枚举
    var transactionType: TransactionType {
        TransactionType(rawValue: type) ?? .expense
    }
    
    // MARK: - Methods
    
    /// 删除分类
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Concurrency
/// 允许在并发闭包中安全捕获 Category（当前场景下使用）
extension Category: @unchecked Sendable {}