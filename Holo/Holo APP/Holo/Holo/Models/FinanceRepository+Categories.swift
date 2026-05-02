//
//  FinanceRepository+Categories.swift
//  Holo
//
//  分类相关操作
//

import Foundation
import CoreData

extension FinanceRepository {

    // MARK: - Category Operations
    
    func getAllCategories() async throws -> [Category] {
        let request = Category.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "type", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]
        return try context.fetch(request)
    }
    
    func getCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@", type.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    /// 获取一级分类（parentId == nil）
    func getTopLevelCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@ AND parentId == nil", type.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    /// 获取指定父分类下的二级子分类
    func getSubCategories(parentId: UUID) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "parentId == %@", parentId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    @discardableResult
    func addCategory(
        name: String,
        icon: String,
        color: String,
        type: TransactionType,
        isDefault: Bool = false,
        parentId: UUID? = nil
    ) async throws -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: icon,
            color: color,
            type: type.rawValue,
            isDefault: isDefault,
            sortOrder: Int16((try? context.count(for: Category.fetchRequest())) ?? 0),
            parentId: parentId
        )
        try context.save()
        return category
    }
    
    /**
     获取最近常用的二级子分类
     
     统计规则：
     1. 查询最近 N 天内的交易记录
     2. 按分类出现频次降序排列
     3. 只返回二级子分类（parentId 非 nil）
     4. 最多返回 limit 个
     
     - Parameters:
       - type: 交易类型（收入/支出）
       - limit: 返回数量上限，默认 8
       - days: 统计的天数窗口，默认 30 天
     - Returns: 按使用频次排序的二级分类数组
     */
    func getRecentCategories(
        type: TransactionType,
        limit: Int = 8,
        days: Int = 30
    ) async throws -> [Category] {
        // 计算时间窗口起点
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        ) ?? Date()
        
        // 查询指定类型、指定时间范围内的所有交易
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND category.type == %@",
            cutoffDate as NSDate,
            type.rawValue
        )
        
        let transactions = try context.fetch(request)
        
        // 统计每个分类的使用次数（仅统计二级子分类）
        var frequencyMap: [NSManagedObjectID: Int] = [:]
        var categoryMap: [NSManagedObjectID: Category] = [:]
        
        for tx in transactions {
            let cat = tx.category
            guard cat.isSubCategory else { continue }
            let oid = cat.objectID
            frequencyMap[oid, default: 0] += 1
            categoryMap[oid] = cat
        }
        
        // 按频次降序取前 limit 个
        let sorted = frequencyMap
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { categoryMap[$0.key] }
        
        return Array(sorted)
    }
    
    func updateCategory(_ category: Category, updates: CategoryUpdates) async throws {
        if let name = updates.name { category.name = name }
        if let icon = updates.icon { category.icon = icon }
        if let color = updates.color { category.color = color }
        if let sortOrder = updates.sortOrder { category.sortOrder = sortOrder }
        try context.save()
    }
    
    func deleteCategory(_ category: Category) async throws {
        // 清理该分类的预算记录
        Budget.deleteForCategory(category.id, in: context)

        // 检查该分类本身是否被交易使用
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "category == %@", category)
        if try context.count(for: request) > 0 {
            throw FinanceError.categoryInUse
        }

        // 检查子分类是否被交易使用，并收集未使用的子分类
        let subRequest = Category.fetchRequest()
        subRequest.predicate = NSPredicate(format: "parentId == %@", category.id as CVarArg)
        let subCategories = try context.fetch(subRequest)

        for sub in subCategories {
            // 清理子分类的预算记录
            Budget.deleteForCategory(sub.id, in: context)

            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(format: "category == %@", sub)
            if try context.count(for: txRequest) > 0 {
                throw FinanceError.categoryInUse
            }
            context.delete(sub)
        }

        context.delete(category)
        try context.save()
    }

    /// 批量清理非预设分类（导入时自动创建的）
    /// - Returns: (已删除数量, 跳过数量-被交易使用)
    func cleanupImportedCategories() async throws -> (deleted: Int, skipped: Int) {
        // 获取所有非预设分类
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "isDefault == NO")
        let nonDefaultCategories = try context.fetch(request)

        var deleted = 0
        var skipped = 0

        for category in nonDefaultCategories {
            // 检查是否被交易使用
            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(format: "category == %@", category)
            let inUse = try context.count(for: txRequest) > 0

            if inUse {
                skipped += 1
            } else {
                context.delete(category)
                deleted += 1
            }
        }

        if deleted > 0 {
            try context.save()
        }

        return (deleted, skipped)
    }

}
