//
//  Category+CoreDataProperties.swift
//  Holo
//
//  分类扩展 - 静态方法和预设数据
//

import Foundation
import CoreData

extension Category {
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Category> {
        return NSFetchRequest<Category>(entityName: "Category")
    }
    
    // MARK: - Factory Methods
    
    /// 创建新的分类
    static func create(
        in context: NSManagedObjectContext,
        name: String,
        icon: String,
        color: String,
        type: String,
        isDefault: Bool = false,
        sortOrder: Int16 = 0
    ) -> Category {
        let category = Category(context: context)
        category.id = UUID()
        category.name = name
        category.icon = icon
        category.color = color
        category.type = type
        category.isDefault = isDefault
        category.sortOrder = sortOrder
        
        return category
    }
    
    // MARK: - Default Categories
    
    /// 预设分类列表（基于常见记账场景）
    /// 支出分类
    static let defaultExpenseCategories = [
        (name: "餐饮", icon: "fork.knife", color: "#FF6B6B"),
        (name: "交通", icon: "car.fill", color: "#4ECDC4"),
        (name: "购物", icon: "bag.fill", color: "#45B7D1"),
        (name: "娱乐", icon: "gamecontroller.fill", color: "#96CEB4"),
        (name: "居住", icon: "house.fill", color: "#FFEAA7"),
        (name: "医疗", icon: "cross.fill", color: "#DDA0DD"),
        (name: "教育", icon: "book.fill", color: "#98D8C8"),
        (name: "通讯", icon: "phone.fill", color: "#F7DC6F"),
        (name: "人情", icon: "gift.fill", color: "#F8B739"),
        (name: "其他", icon: "ellipsis.circle.fill", color: "#AEB6BF")
    ]
    
    /// 收入分类
    static let defaultIncomeCategories = [
        (name: "工资", icon: "banknote.fill", color: "#74B9FF"),
        (name: "理财", icon: "chart.line.fill", color: "#A29BFE"),
        (name: "兼职", icon: "briefcase.fill", color: "#FDCB6E"),
        (name: "奖金", icon: "star.fill", color: "#FFEAA7"),
        (name: "其他", icon: "plus.circle.fill", color: "#55E6C1")
    ]
    
    /// 初始化默认分类数据
    /// 在首次启动时调用，确保用户有可用的分类
    static func seedDefaultCategories(in context: NSManagedObjectContext) {
        // 检查是否已存在分类
        let fetchRequest = Category.fetchRequest()
        fetchRequest.fetchLimit = 1
        
        if (try? context.count(for: fetchRequest)) ?? 0 > 0 {
            return // 已有分类，跳过初始化
        }
        
        // 创建支出分类
        for (index, category) in defaultExpenseCategories.enumerated() {
            _ = create(
                in: context,
                name: category.name,
                icon: category.icon,
                color: category.color,
                type: TransactionType.expense.rawValue,
                isDefault: true,
                sortOrder: Int16(index)
            )
        }
        
        // 创建收入分类
        for (index, category) in defaultIncomeCategories.enumerated() {
            _ = create(
                in: context,
                name: category.name,
                icon: category.icon,
                color: category.color,
                type: TransactionType.income.rawValue,
                isDefault: true,
                sortOrder: Int16(index)
            )
        }
        
        // 保存上下文
        try? context.save()
    }
}