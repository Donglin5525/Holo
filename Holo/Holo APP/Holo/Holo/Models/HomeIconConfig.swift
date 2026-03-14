//
//  HomeIconConfig.swift
//  Holo
//
//  首页图标配置实体类
//  用于持久化存储首页功能图标的排序、可见性等配置
//  支持 iCloud 同步
//

import Foundation
import CoreData

/// 首页图标配置实体
/// 存储用户对首页功能入口图标的个性化设置
@objc(HomeIconConfig)
public class HomeIconConfig: NSManagedObject {
    
    // MARK: - Properties
    
    /// 图标唯一标识符（如 "task", "finance", "habit" 等）
    @NSManaged public var iconId: String
    
    /// 排序顺序（0-based，数字越小越靠前）
    @NSManaged public var sortOrder: Int16
    
    /// 是否显示（支持用户隐藏某些图标）
    @NSManaged public var isVisible: Bool
    
    /// 自定义名称（可选，用户可修改显示名称）
    @NSManaged public var customName: String?
    
    /// 创建时间
    @NSManaged public var createdAt: Date
    
    /// 更新时间
    @NSManaged public var updatedAt: Date
    
    // MARK: - Methods
    
    /// 删除配置
    public func delete() {
        managedObjectContext?.delete(self)
    }
    
    /// 更新排序顺序
    public func updateSortOrder(_ order: Int16) {
        sortOrder = order
        updatedAt = Date()
    }
    
    /// 更新可见性
    public func updateVisibility(_ visible: Bool) {
        isVisible = visible
        updatedAt = Date()
    }
    
    /// 更新自定义名称
    public func updateCustomName(_ name: String?) {
        customName = name
        updatedAt = Date()
    }
}

// MARK: - Concurrency

extension HomeIconConfig: @unchecked Sendable {}
