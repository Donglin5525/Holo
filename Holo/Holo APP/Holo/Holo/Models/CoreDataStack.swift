//
//  CoreDataStack.swift
//  Holo
//
//  Core Data 数据栈管理器
//  负责管理 Core Data 的持久化容器、上下文和保存操作
//
//  ━━━━━━━━━━ iCloud 同步启用指南 ━━━━━━━━━━
//  当前使用 NSPersistentContainer，数据仅存储在本地。
//  要启用 iCloud 同步，请按以下步骤操作：
//
//  1. 在 Xcode 中启用 CloudKit 能力：
//     - 选择项目 Target → Signing & Capabilities
//     - 点击 "+ Capability" 添加 "iCloud"
//     - 勾选 "CloudKit" 并创建容器（如 iCloud.com.yourcompany.Holo）
//
//  2. 修改下方代码：
//     - 将 `NSPersistentContainer` 改为 `NSPersistentCloudKitContainer`
//     - 取消注释 CloudKit 相关配置
//
//  3. 首次启用后，在 CloudKit Dashboard 中验证 schema 自动创建
//
//  注意：CloudKit 同步需要真机测试，模拟器功能有限
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import CoreData

/// Core Data 数据栈单例
/// 提供统一的 Core Data 访问入口，确保数据一致性
class CoreDataStack {
    
    // MARK: - Singleton
    
    /// 共享实例
    static let shared = CoreDataStack()
    
    // MARK: - Properties
    
    /// 持久化容器
    /// 管理 Core Data 的持久化存储和协调
    /// 
    /// 【启用 iCloud 同步】将下方 NSPersistentContainer 改为 NSPersistentCloudKitContainer
    lazy var persistentContainer: NSPersistentContainer = {
        // 通过代码创建数据模型
        let model = createDataModel()
        
        // ━━━ 本地存储（当前使用）━━━
        let container = NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)
        
        // ━━━ iCloud 同步（取消注释以启用）━━━
        // let container = NSPersistentCloudKitContainer(name: "HoloDataModel", managedObjectModel: model)
        
        // 配置持久化存储
        if let description = container.persistentStoreDescriptions.first {
            // 使用 SQLite 存储
            description.url = URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")
            
            // 启用轻量级迁移（支持新增字段等 schema 变更）
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            
            // 启用历史追踪（iCloud 同步必需）
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            
            // 启用远程变更通知（iCloud 同步必需）
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            
            // ━━━ iCloud 同步配置（取消注释以启用）━━━
            // description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            //     containerIdentifier: "iCloud.com.yourcompany.Holo"  // 替换为你的 CloudKit 容器 ID
            // )
        }
        
        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Core Data 存储加载失败：\(error.localizedDescription)")
            }
        }
        
        // 配置自动合并策略
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        return container
    }()
    
    /// 通过代码创建 Core Data 数据模型
    /// - Returns: NSManagedObjectModel
    private func createDataModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        
        // MARK: - Transaction Entity
        let transactionEntity = NSEntityDescription()
        transactionEntity.name = "Transaction"
        transactionEntity.managedObjectClassName = "Transaction"
        
        var attributes: [NSAttributeDescription] = []
        
        let transactionId = NSAttributeDescription()
        transactionId.name = "id"
        transactionId.attributeType = .UUIDAttributeType
        transactionId.isOptional = false
        transactionId.isIndexed = true
        attributes.append(transactionId)
        
        let amount = NSAttributeDescription()
        amount.name = "amount"
        amount.attributeType = .decimalAttributeType
        amount.isOptional = false
        attributes.append(amount)
        
        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false
        type.isIndexed = true
        attributes.append(type)
        
        // 不再使用 categoryId/accountId 属性，仅通过 relationship category/account 关联
        
        let date = NSAttributeDescription()
        date.name = "date"
        date.attributeType = .dateAttributeType
        date.isOptional = false
        date.isIndexed = true
        attributes.append(date)
        
        let note = NSAttributeDescription()
        note.name = "note"
        note.attributeType = .stringAttributeType
        note.isOptional = true
        attributes.append(note)
        
        let tags = NSAttributeDescription()
        tags.name = "tags"
        tags.attributeType = .transformableAttributeType
        tags.isOptional = true
        tags.attributeValueClassName = "NSArray"
        attributes.append(tags)
        
        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false
        attributes.append(createdAt)
        
        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false
        attributes.append(updatedAt)
        
        // Transaction 与 Category / Account 的关系（对应 Transaction.category / Transaction.account）
        let categoryRelation = NSRelationshipDescription()
        categoryRelation.name = "category"
        categoryRelation.destinationEntity = nil  // 稍后设置，避免循环引用
        categoryRelation.minCount = 1
        categoryRelation.maxCount = 1
        categoryRelation.isOptional = false
        
        let accountRelation = NSRelationshipDescription()
        accountRelation.name = "account"
        accountRelation.destinationEntity = nil
        accountRelation.minCount = 1
        accountRelation.maxCount = 1
        accountRelation.isOptional = false
        
        transactionEntity.properties = attributes + [categoryRelation, accountRelation]
        
        // MARK: - Category Entity
        let categoryEntity = NSEntityDescription()
        categoryEntity.name = "Category"
        categoryEntity.managedObjectClassName = "Category"
        
        var categoryAttributes: [NSAttributeDescription] = []
        
        let categoryIdAttr = NSAttributeDescription()
        categoryIdAttr.name = "id"
        categoryIdAttr.attributeType = .UUIDAttributeType
        categoryIdAttr.isOptional = false
        categoryIdAttr.isIndexed = true
        categoryAttributes.append(categoryIdAttr)
        
        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        categoryAttributes.append(name)
        
        let icon = NSAttributeDescription()
        icon.name = "icon"
        icon.attributeType = .stringAttributeType
        icon.isOptional = false
        categoryAttributes.append(icon)
        
        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = false
        categoryAttributes.append(color)
        
        let categoryType = NSAttributeDescription()
        categoryType.name = "type"
        categoryType.attributeType = .stringAttributeType
        categoryType.isOptional = false
        categoryType.isIndexed = true
        categoryAttributes.append(categoryType)
        
        let isDefault = NSAttributeDescription()
        isDefault.name = "isDefault"
        isDefault.attributeType = .booleanAttributeType
        isDefault.isOptional = false
        isDefault.isIndexed = true
        categoryAttributes.append(isDefault)
        
        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.isIndexed = true
        categoryAttributes.append(sortOrder)
        
        // 父分类 ID（用于二级分类层级关系）
        // 一级分类的 parentId 为 nil，二级分类通过此字段指向其一级分类
        let parentId = NSAttributeDescription()
        parentId.name = "parentId"
        parentId.attributeType = .UUIDAttributeType
        parentId.isOptional = true
        parentId.isIndexed = true
        categoryAttributes.append(parentId)
        
        categoryEntity.properties = categoryAttributes
        
        // MARK: - Account Entity
        let accountEntity = NSEntityDescription()
        accountEntity.name = "Account"
        accountEntity.managedObjectClassName = "Account"
        
        var accountAttributes: [NSAttributeDescription] = []
        
        let accountIdAttr = NSAttributeDescription()
        accountIdAttr.name = "id"
        accountIdAttr.attributeType = .UUIDAttributeType
        accountIdAttr.isOptional = false
        accountIdAttr.isIndexed = true
        accountAttributes.append(accountIdAttr)
        
        let accountName = NSAttributeDescription()
        accountName.name = "name"
        accountName.attributeType = .stringAttributeType
        accountName.isOptional = false
        accountAttributes.append(accountName)
        
        let accountType = NSAttributeDescription()
        accountType.name = "type"
        accountType.attributeType = .stringAttributeType
        accountType.isOptional = false
        accountType.isIndexed = true
        accountAttributes.append(accountType)
        
        let accountIsDefault = NSAttributeDescription()
        accountIsDefault.name = "isDefault"
        accountIsDefault.attributeType = .booleanAttributeType
        accountIsDefault.isOptional = false
        accountIsDefault.isIndexed = true
        accountAttributes.append(accountIsDefault)
        
        accountEntity.properties = accountAttributes
        
        // 绑定 Transaction 关系的目标实体（需在 Category/Account 创建后设置）
        categoryRelation.destinationEntity = categoryEntity
        accountRelation.destinationEntity = accountEntity
        
        // MARK: - HomeIconConfig Entity
        // 首页图标配置实体，支持排序、显示/隐藏、自定义名称等
        let homeIconConfigEntity = NSEntityDescription()
        homeIconConfigEntity.name = "HomeIconConfig"
        homeIconConfigEntity.managedObjectClassName = "HomeIconConfig"
        
        var homeIconAttributes: [NSAttributeDescription] = []
        
        // 图标唯一标识符（如 "task", "finance", "habit" 等）
        let iconId = NSAttributeDescription()
        iconId.name = "iconId"
        iconId.attributeType = .stringAttributeType
        iconId.isOptional = false
        iconId.isIndexed = true
        homeIconAttributes.append(iconId)
        
        // 排序顺序（0-based，数字越小越靠前）
        let iconSortOrder = NSAttributeDescription()
        iconSortOrder.name = "sortOrder"
        iconSortOrder.attributeType = .integer16AttributeType
        iconSortOrder.isOptional = false
        iconSortOrder.isIndexed = true
        homeIconAttributes.append(iconSortOrder)
        
        // 是否显示（支持用户隐藏某些图标）
        let iconIsVisible = NSAttributeDescription()
        iconIsVisible.name = "isVisible"
        iconIsVisible.attributeType = .booleanAttributeType
        iconIsVisible.isOptional = false
        iconIsVisible.defaultValue = true
        homeIconAttributes.append(iconIsVisible)
        
        // 自定义名称（可选，用户可修改显示名称）
        let iconCustomName = NSAttributeDescription()
        iconCustomName.name = "customName"
        iconCustomName.attributeType = .stringAttributeType
        iconCustomName.isOptional = true
        homeIconAttributes.append(iconCustomName)
        
        // 创建时间
        let iconCreatedAt = NSAttributeDescription()
        iconCreatedAt.name = "createdAt"
        iconCreatedAt.attributeType = .dateAttributeType
        iconCreatedAt.isOptional = false
        homeIconAttributes.append(iconCreatedAt)
        
        // 更新时间
        let iconUpdatedAt = NSAttributeDescription()
        iconUpdatedAt.name = "updatedAt"
        iconUpdatedAt.attributeType = .dateAttributeType
        iconUpdatedAt.isOptional = false
        homeIconAttributes.append(iconUpdatedAt)
        
        homeIconConfigEntity.properties = homeIconAttributes
        
        // Add entities to model
        model.entities = [transactionEntity, categoryEntity, accountEntity, homeIconConfigEntity]
        
        return model
    }
    
    /// 主上下文（用于 UI 操作）
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    // MARK: - Initialization
    
    /// 私有初始化方法（单例模式）
    private init() {}
    
    // MARK: - Context Management
    
    /// 创建新的后台上下文
    /// 用于执行耗时的数据操作，避免阻塞主线程
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    /// 执行后台任务
    /// 在后台上下文中执行闭包，完成后自动保存
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                do {
                    let result = try block(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Save Operations
    
    /// 保存主上下文
    /// 将更改写入持久化存储
    func save() throws {
        let context = viewContext
        if context.hasChanges {
            try context.save()
        }
    }
    
    /// 保存指定上下文
    func save(_ context: NSManagedObjectContext) throws {
        if context.hasChanges {
            try context.save()
        }
    }
    
    // MARK: - Reset
    
    /// 重置数据栈（用于开发调试）
    /// 警告：这将删除所有数据
    func reset() throws {
        let coordinator = persistentContainer.persistentStoreCoordinator
        
        // 删除所有存储
        for store in coordinator.persistentStores {
            try coordinator.destroyPersistentStore(
                at: store.url ?? URL(fileURLWithPath: "/dev/null"),
                type: NSPersistentStore.StoreType(rawValue: store.type),
                options: nil
            )
        }
        
        // 重新加载存储
        persistentContainer.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data 重置失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Helper Extensions

extension NSManagedObjectContext {
    /// 批量插入对象
    /// 提高大量数据插入时的性能
    func batchInsert<T: NSManagedObject>(
        entities: [T],
        batchSize: Int = 100
    ) throws {
        for (index, entity) in entities.enumerated() {
            insert(entity)
            
            // 每 batchSize 条保存一次，避免内存占用过高
            if (index + 1) % batchSize == 0 {
                try save()
                refreshAllObjects()
            }
        }
        
        // 保存剩余数据
        if !hasChanges {
            try save()
        }
    }
}
