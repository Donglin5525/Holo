//
//  HomeIconConfig+CoreDataProperties.swift
//  Holo
//
//  首页图标配置扩展 - 工厂方法和默认数据初始化
//

import Foundation
import CoreData

extension HomeIconConfig {
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<HomeIconConfig> {
        return NSFetchRequest<HomeIconConfig>(entityName: "HomeIconConfig")
    }
    
    // MARK: - Factory Methods
    
    /**
     创建新的图标配置实体
     - Parameters:
       - context: Core Data 上下文
       - iconId: 图标唯一标识符
       - sortOrder: 排序顺序
       - isVisible: 是否显示
       - customName: 自定义名称（可选）
     - Returns: 创建好的 HomeIconConfig 实例
     */
    static func create(
        in context: NSManagedObjectContext,
        iconId: String,
        sortOrder: Int16,
        isVisible: Bool = true,
        customName: String? = nil
    ) -> HomeIconConfig {
        let config = HomeIconConfig(context: context)
        config.iconId = iconId
        config.sortOrder = sortOrder
        config.isVisible = isVisible
        config.customName = customName
        config.createdAt = Date()
        config.updatedAt = Date()
        return config
    }
    
    // MARK: - 默认图标配置
    
    /// 默认的首页图标ID列表（按初始排序顺序）
    static let defaultIconIds: [String] = [
        "task",      // 任务
        "finance",   // 财务
        "habit",     // 习惯
        "health",    // 健康
        "thoughts"   // 观点
    ]
    
    // MARK: - Seed 初始化
    
    /**
     初始化默认图标配置数据（首次启动时调用）
     
     处理逻辑：
     1. 检查是否已有配置数据
     2. 若无配置，创建默认的 5 个图标配置
     3. 若已有配置但缺少某些图标（如版本更新新增了图标），补充缺失的配置
     */
    static func seedDefaultConfigs(in context: NSManagedObjectContext) {
        let request = HomeIconConfig.fetchRequest()
        guard let existing = try? context.fetch(request) else { return }
        
        // 获取已存在的图标ID集合
        let existingIds = Set(existing.map { $0.iconId })
        
        // 找到当前最大的 sortOrder
        let maxSortOrder = existing.map { $0.sortOrder }.max() ?? -1
        var nextSortOrder = maxSortOrder + 1
        
        // 遍历默认图标列表，补充缺失的配置
        for (index, iconId) in defaultIconIds.enumerated() {
            if !existingIds.contains(iconId) {
                // 新图标：如果是首次创建（无任何配置），使用默认顺序；否则追加到末尾
                let order: Int16 = existing.isEmpty ? Int16(index) : nextSortOrder
                _ = create(
                    in: context,
                    iconId: iconId,
                    sortOrder: order,
                    isVisible: true
                )
                nextSortOrder += 1
            }
        }
        
        // 保存更改
        if context.hasChanges {
            try? context.save()
        }
    }
    
    // MARK: - Query Helpers
    
    /**
     获取所有可见的图标配置，按 sortOrder 排序
     - Parameter context: Core Data 上下文
     - Returns: 排序后的可见图标配置数组
     */
    static func fetchVisibleConfigs(in context: NSManagedObjectContext) -> [HomeIconConfig] {
        let request = HomeIconConfig.fetchRequest()
        request.predicate = NSPredicate(format: "isVisible == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        
        return (try? context.fetch(request)) ?? []
    }
    
    /**
     获取所有图标配置，按 sortOrder 排序
     - Parameter context: Core Data 上下文
     - Returns: 排序后的所有图标配置数组
     */
    static func fetchAllConfigs(in context: NSManagedObjectContext) -> [HomeIconConfig] {
        let request = HomeIconConfig.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        
        return (try? context.fetch(request)) ?? []
    }
    
    /**
     根据 iconId 获取配置
     - Parameters:
       - iconId: 图标标识符
       - context: Core Data 上下文
     - Returns: 对应的配置，若不存在返回 nil
     */
    static func fetchConfig(byIconId iconId: String, in context: NSManagedObjectContext) -> HomeIconConfig? {
        let request = HomeIconConfig.fetchRequest()
        request.predicate = NSPredicate(format: "iconId == %@", iconId)
        request.fetchLimit = 1
        
        return try? context.fetch(request).first
    }
    
    /**
     批量更新排序顺序
     - Parameters:
       - orderedIds: 按新顺序排列的图标ID数组
       - context: Core Data 上下文
     */
    static func updateSortOrder(_ orderedIds: [String], in context: NSManagedObjectContext) {
        for (index, iconId) in orderedIds.enumerated() {
            if let config = fetchConfig(byIconId: iconId, in: context) {
                config.updateSortOrder(Int16(index))
            }
        }
        
        if context.hasChanges {
            try? context.save()
        }
    }
}
