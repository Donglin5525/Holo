//
//  HomeIconConfigRepository.swift
//  Holo
//
//  首页图标配置数据仓库
//  管理首页功能图标的排序、可见性等配置的持久化
//

import Foundation
import CoreData
import Combine

/// 首页图标配置数据仓库
/// 使用 @MainActor 保证所有操作在主线程执行
@MainActor
class HomeIconConfigRepository: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = HomeIconConfigRepository()
    
    // MARK: - Published Properties
    
    /// 当前可见的图标配置列表（按 sortOrder 排序）
    @Published private(set) var visibleConfigs: [HomeIconConfig] = []
    
    /// 所有图标配置列表（包括隐藏的）
    @Published private(set) var allConfigs: [HomeIconConfig] = []
    
    // MARK: - Properties
    
    /// 主上下文
    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }
    
    // MARK: - Initialization
    
    private init() {
        // 初始化默认数据
        seedDefaultData()
        // 加载配置
        loadConfigs()
    }
    
    // MARK: - Seed Data
    
    /// 初始化默认图标配置
    private func seedDefaultData() {
        HomeIconConfig.seedDefaultConfigs(in: context)
    }
    
    // MARK: - Load Data
    
    /// 从数据库加载配置
    func loadConfigs() {
        allConfigs = HomeIconConfig.fetchAllConfigs(in: context)
        visibleConfigs = HomeIconConfig.fetchVisibleConfigs(in: context)
    }
    
    // MARK: - Reorder Operations
    
    /**
     更新图标排序顺序
     
     当用户拖拽图标后调用此方法保存新顺序
     
     - Parameter orderedIconIds: 按新顺序排列的图标ID数组
     */
    func updateOrder(_ orderedIconIds: [String]) {
        HomeIconConfig.updateSortOrder(orderedIconIds, in: context)
        loadConfigs()
    }
    
    /**
     交换两个图标的位置
     
     - Parameters:
       - fromIconId: 源图标ID
       - toIconId: 目标图标ID
     */
    func swapIcons(_ fromIconId: String, _ toIconId: String) {
        guard let fromConfig = HomeIconConfig.fetchConfig(byIconId: fromIconId, in: context),
              let toConfig = HomeIconConfig.fetchConfig(byIconId: toIconId, in: context) else {
            return
        }
        
        // 交换 sortOrder
        let tempOrder = fromConfig.sortOrder
        fromConfig.updateSortOrder(toConfig.sortOrder)
        toConfig.updateSortOrder(tempOrder)
        
        // 保存并刷新
        try? context.save()
        loadConfigs()
    }
    
    // MARK: - Visibility Operations
    
    /**
     设置图标可见性
     
     - Parameters:
       - iconId: 图标ID
       - isVisible: 是否可见
     */
    func setVisibility(iconId: String, isVisible: Bool) {
        guard let config = HomeIconConfig.fetchConfig(byIconId: iconId, in: context) else {
            return
        }
        
        config.updateVisibility(isVisible)
        try? context.save()
        loadConfigs()
    }
    
    // MARK: - Custom Name Operations
    
    /**
     设置图标自定义名称
     
     - Parameters:
       - iconId: 图标ID
       - customName: 自定义名称，nil 表示使用默认名称
     */
    func setCustomName(iconId: String, customName: String?) {
        guard let config = HomeIconConfig.fetchConfig(byIconId: iconId, in: context) else {
            return
        }
        
        config.updateCustomName(customName)
        try? context.save()
        loadConfigs()
    }
    
    // MARK: - Query Operations
    
    /**
     获取可见图标的ID列表（按排序顺序）
     
     - Returns: 图标ID数组
     */
    func getVisibleIconIds() -> [String] {
        return visibleConfigs.map { $0.iconId }
    }
    
    /**
     获取指定图标的配置
     
     - Parameter iconId: 图标ID
     - Returns: 图标配置，若不存在返回 nil
     */
    func getConfig(byIconId iconId: String) -> HomeIconConfig? {
        return allConfigs.first { $0.iconId == iconId }
    }
    
    /**
     获取指定图标的显示名称
     
     优先返回自定义名称，若无则返回 nil（由调用方使用默认名称）
     
     - Parameter iconId: 图标ID
     - Returns: 自定义名称或 nil
     */
    func getDisplayName(forIconId iconId: String) -> String? {
        return getConfig(byIconId: iconId)?.customName
    }
    
    // MARK: - Add New Icon (for future extension)
    
    /**
     添加新的图标配置
     
     用于后续版本新增功能入口时调用
     
     - Parameters:
       - iconId: 图标ID
       - isVisible: 是否可见，默认 true
     - Returns: 创建的配置实体
     */
    @discardableResult
    func addIcon(iconId: String, isVisible: Bool = true) -> HomeIconConfig {
        // 获取当前最大 sortOrder
        let maxOrder = allConfigs.map { $0.sortOrder }.max() ?? -1
        
        let config = HomeIconConfig.create(
            in: context,
            iconId: iconId,
            sortOrder: maxOrder + 1,
            isVisible: isVisible
        )
        
        try? context.save()
        loadConfigs()
        
        return config
    }
}
