//
//  CoreDataStack.swift
//  Holo
//
//  Core Data 数据栈管理器
//  负责管理 Core Data 的持久化容器、上下文和保存操作
//

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
    lazy var persistentContainer: NSPersistentContainer = {
        // 通过代码创建数据模型
        let model = createDataModel()
        let container = NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)
        
        // 配置持久化存储
        if let description = container.persistentStoreDescriptions.first {
            // 使用 SQLite 存储
            description.url = URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")
            
            // 启用轻量级迁移（支持新增 parentId 字段等 schema 变更）
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            
            // 启用历史追踪（用于增量同步）
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            
            // 启用删除规则验证
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
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
        
        // Add entities to model
        model.entities = [transactionEntity, categoryEntity, accountEntity]
        
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
