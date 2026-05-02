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
/// 线程安全：支持后台线程预加载，主线程安全访问
class CoreDataStack {

    // MARK: - Singleton

    /// 共享实例
    nonisolated(unsafe) static let shared = CoreDataStack()

    // MARK: - Thread-Safe Properties

    /// 线程安全锁，保护 _persistentContainer 的读写
    nonisolated(unsafe) private let lock = NSLock()

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

        let container = NSPersistentContainer(name: "HoloDataModel", managedObjectModel: model)

        if let description = container.persistentStoreDescriptions.first {
            description.url = URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")

            // 异步加载：不阻塞调用线程，避免主线程死锁
            // store 加载完成后通过 completion handler 信号通知
            description.shouldAddStoreAsynchronously = true

            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        container.loadPersistentStores { [weak self] _, error in
            if let error = error {
                fatalError("Core Data 存储加载失败：\(error.localizedDescription)")
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
        entities.append(contentsOf: createFinanceEntities())
        entities.append(contentsOf: createHabitEntities())
        entities.append(contentsOf: createTodoEntities())
        entities.append(contentsOf: createThoughtEntities())
        entities.append(contentsOf: createChatEntities())
        entities.append(createMemoryInsightEntity())
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

        lock.lock()
        if _storeLoaded {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock()
            if _storeLoaded {
                lock.unlock()
                continuation.resume()
                return
            }
            _storeLoadContinuations.append(continuation)
            lock.unlock()
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
