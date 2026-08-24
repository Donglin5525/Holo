//
//  CoreDataStack.swift
//  Holo
//
//  Core Data 数据栈管理器
//  负责管理 Core Data 的持久化容器、上下文和保存操作
//
//  使用 NSPersistentCloudKitContainer 将本地 Core Data store 镜像到用户的 iCloud 私有数据库。
//  业务层仍通过 Core Data Repository 读写本地 store；同步由系统在后台调度。

import CoreData
import CloudKit

/// Core Data 数据栈单例
/// 提供统一的 Core Data 访问入口，确保数据一致性
/// 线程安全：支持后台线程预加载，主线程安全访问
nonisolated class CoreDataStack {

    // MARK: - Singleton

    /// 共享实例
    static let shared = CoreDataStack()

    // MARK: - Thread-Safe Properties

    /// 线程安全锁，保护 _persistentContainer 的读写
    private let lock = NSLock()

    /// 持久化容器（线程安全存储）
    nonisolated(unsafe) private var _persistentContainer: NSPersistentContainer?

    /// Store 是否已加载完毕
    nonisolated(unsafe) private var _storeLoaded = false

    /// 等待 store 加载完毕的 continuation 列表
    nonisolated(unsafe) private var _storeLoadContinuations: [CheckedContinuation<Void, Never>] = []

    /// 持久化容器（线程安全延迟初始化）
    /// 首次访问时创建容器并异步加载 store，不阻塞调用线程
    nonisolated var persistentContainer: NSPersistentContainer {
        lock.lock()
        if let container = _persistentContainer {
            lock.unlock()
            return container
        }

        let container = buildContainer()
        _persistentContainer = container
        lock.unlock()
        return container
    }

    /// Core Data store 是否已加载完毕
    nonisolated var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _storeLoaded
    }
    
    /// 构建并异步加载持久化容器
    /// store 加载在后台进行，不阻塞调用线程
    /// 加载完成后通过 resume continuations 通知 await waitUntilReady() 的调用方
    nonisolated func buildContainer() -> NSPersistentContainer {
        let model = createDataModel()

        let cloudKitAvailable = CloudKitRuntimeAvailability.isAvailable
        let container: NSPersistentContainer = cloudKitAvailable
            ? NSPersistentCloudKitContainer(name: "HoloDataModel", managedObjectModel: model)
            : NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)

        if let description = container.persistentStoreDescriptions.first {
            description.url = URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")

            // 异步加载：不阻塞调用线程，避免主线程死锁
            // store 加载完成后通过 completion handler 信号通知
            description.shouldAddStoreAsynchronously = true

            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            if cloudKitAvailable {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: CloudKitRuntimeAvailability.containerIdentifier
                )
            }
        }

        container.loadPersistentStores { [weak self] _, error in
            if let error = error {
                let nsError = error as NSError
                fatalError("Core Data 存储加载失败：\(error.localizedDescription)\n\(nsError)\nuserInfo: \(nsError.userInfo)")
            }
            guard let self else { return }
            self.lock.lock()
            self._storeLoaded = true
            let continuations = self._storeLoadContinuations
            self._storeLoadContinuations = []
            self.lock.unlock()
            for continuation in continuations {
                continuation.resume()
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return container
    }

    /// 通过代码创建 Core Data 数据模型
    /// - Returns: NSManagedObjectModel
    nonisolated func createDataModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        var entities: [NSEntityDescription] = []
        let goalEntity = createGoalEntity()
        // 先创建 Thought 实体，取出 thoughtEntity 供 Todo 建立 sourceThought 关联
        let thoughtEntities = createThoughtEntities()
        let thoughtEntity = thoughtEntities[0]
        entities.append(contentsOf: createFinanceEntities())
        entities.append(contentsOf: createHabitEntities(goalEntity: goalEntity))
        entities.append(contentsOf: createTodoEntities(goalEntity: goalEntity, thoughtEntity: thoughtEntity))
        entities.append(contentsOf: thoughtEntities)
        entities.append(contentsOf: createChatEntities())
        entities.append(contentsOf: createSyncEntities())
        entities.append(createMemoryInsightEntity())
        entities.append(createMemoryInsightFeedbackEntity())
        entities.append(contentsOf: HoloMemoryManagedObjectModelFactory.makeEntities())
        // 纪念日模块使用程序化 Core Data 模型；必须在首屏仓库查询前注册实体。
        entities.append(createAnniversaryEntity())
        entities.append(goalEntity)
        // 量化目标手动记录（goalId 外键关联 Goal，不建 relationship）
        entities.append(createGoalMetricLogEntity())
        // LifePlan 计划台账（六对象，ID 外键、无跨域关系）
        entities.append(contentsOf: createLifePlanEntities())
        // 回收站清空批次（数据清理功能）
        entities.append(contentsOf: createRecycleBinEntities())
        model.entities = entities
        return model
    }

    /// 主上下文（用于 UI 操作）
    nonisolated var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    // MARK: - Initialization

    /// 私有初始化方法（单例模式）
    nonisolated private init() {}

    /// 触发异步 store 加载，不阻塞调用线程（在 HoloApp.init() 中调用）
    func prepareIfNeeded() {
        _ = persistentContainer
    }

    /// 等待 store 加载完毕（在 HomeView.task 中 await 调用）
    /// 若 store 已加载则立即返回；否则挂起当前协程直到 loadPersistentStores 完成
    func waitUntilReady() async {
        prepareIfNeeded()

        let didLoad = lock.withLock {
            _storeLoaded
        }
        if didLoad {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if _storeLoaded {
                    return true
                }
                _storeLoadContinuations.append(continuation)
                return false
            }

            if shouldResume {
                continuation.resume()
            }
        }
    }

    // MARK: - Context Management
    
    /// 创建新的后台上下文
    /// 用于执行耗时的数据操作，避免阻塞主线程
    nonisolated func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    /// 执行后台任务
    /// 在后台上下文中执行闭包，完成后自动保存
    nonisolated func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
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

    #if DEBUG
    /// Debug 专用：验证 CloudKit schema 是否兼容当前 Core Data 模型（不上传到 CloudKit）
    func validateCloudKitSchemaDryRun() throws {
        guard let container = _persistentContainer as? NSPersistentCloudKitContainer else {
            return
        }
        try container.initializeCloudKitSchema(options: [.dryRun, .printSchema])
    }
    #endif
    
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

    // MARK: - 软删除属性工具

    /// 统一软删除属性集（deletedAt / deletedBatchId），供各实体工厂接入。
    /// attributes 会放进实体 properties，两个属性实例可直接引用到索引字典；
    /// 同一实体只调用一次，保证 properties 与索引引用同一批实例。
    struct SoftDeleteAttributeSet {
        let deletedAt: NSAttributeDescription
        let deletedBatchId: NSAttributeDescription
        var attributes: [NSAttributeDescription] { [deletedAt, deletedBatchId] }
    }

    nonisolated static func makeSoftDeleteAttributes() -> SoftDeleteAttributeSet {
        let deletedAt = NSAttributeDescription()
        deletedAt.name = "deletedAt"
        deletedAt.attributeType = .dateAttributeType
        deletedAt.isOptional = true

        let deletedBatchId = NSAttributeDescription()
        deletedBatchId.name = "deletedBatchId"
        deletedBatchId.attributeType = .UUIDAttributeType
        deletedBatchId.isOptional = true

        return SoftDeleteAttributeSet(deletedAt: deletedAt, deletedBatchId: deletedBatchId)
    }

    // MARK: - 程序化模型索引工具

    /// 为程序化定义的实体批量设置单属性索引，替代已弃用的 NSAttributeDescription.isIndexed。
    /// - Parameters:
    ///   - entity: 目标实体（需已设置 properties）
    ///   - indexes: 索引名 → 属性 的映射；每个属性生成一个 binary 排序的单列索引
    nonisolated static func applyIndexes(
        to entity: NSEntityDescription,
        on indexes: [String: NSPropertyDescription]
    ) {
        guard !indexes.isEmpty else { return }
        let entityName = entity.name ?? "Entity"
        entity.indexes = indexes.map { indexName, property in
            NSFetchIndexDescription(
                name: "\(entityName)_\(indexName)_idx",
                elements: [NSFetchIndexElementDescription(property: property, collationType: .binary)]
            )
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
