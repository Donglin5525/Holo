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
import os.log

/// Core Data 数据栈单例
/// 提供统一的 Core Data 访问入口，确保数据一致性
/// 线程安全：支持后台线程预加载，主线程安全访问
nonisolated class CoreDataStack {

    // MARK: - Singleton

    /// 共享实例
    static let shared = CoreDataStack()

    // MARK: - Thread-Safe Properties

    /// 线程安全锁，保护 _persistentContainer / _storeLoaded / continuations 的读写（只做瞬时状态存取，绝不在持锁期间调用 CoreData）
    private let lock = NSLock()

    /// 仅序列化容器构建过程。锁序固定 buildLock → lock 单向获取，杜绝倒致死锁
    private let buildLock = NSLock()

    /// 持久化容器（线程安全存储）
    nonisolated(unsafe) private var _persistentContainer: NSPersistentContainer?

    /// Store 是否已加载完毕
    nonisolated(unsafe) private var _storeLoaded = false

    /// 等待 store 加载完毕的 continuation 列表
    nonisolated(unsafe) private var _storeLoadContinuations: [CheckedContinuation<Void, Never>] = []

    /// R01（2026-10-04 体检）：加载终态。true = 成功或失败已定，后续等待方立即返回。
    /// 失败不再终止进程；失败原因存 _storeLoadError 供恢复门如实展示。
    nonisolated(unsafe) private var _storeLoadSettled = false
    nonisolated(unsafe) private var _storeLoadError: Error?

    /// 持久化容器（线程安全延迟初始化）
    /// 首次访问时创建容器并异步加载 store，不阻塞调用线程。
    /// 构建期间不得持有 lock：store 加载完成回调需要拿 lock 置位 _storeLoaded，
    /// 若构建线程持锁做 CoreData 工作（viewContext 配置会同步等装载队列），
    /// 两条队列互等即死锁（2026-09-17 全新安装首启三方锁实锤）。
    nonisolated var persistentContainer: NSPersistentContainer {
        lock.lock()
        if let container = _persistentContainer {
            lock.unlock()
            return container
        }
        lock.unlock()

        // 并发首建由 buildLock 定唯一胜者；后来者二次检查后复用胜者容器
        buildLock.lock()
        defer { buildLock.unlock() }

        lock.lock()
        if let container = _persistentContainer {
            lock.unlock()
            return container
        }
        lock.unlock()

        let container = buildContainer()
        lock.lock()
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
            description.url = Self.resolveStoreURLForMigration(model: model)

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

        Self.loadStoreAllowingRecovery(container, logger: Self.recoveryLogger) { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let continuations: [CheckedContinuation<Void, Never>]
            if let error {
                // R01（2026-10-04 体检）：加载失败是可恢复状态，不再终止进程——
                // 记录失败原因、置终态并唤醒所有等待方；恢复门（StoreConflictRecoveryGate）
                // 在等待返回后如实说明并保留原库等待救援。破坏性重建必须有完整数据保护前提。
                Self.recoveryLogger.fault("Core Data 存储加载失败（自动恢复后仍不可用），进入可恢复失败状态：\(error.localizedDescription, privacy: .public)\n\((error as NSError).userInfo)")
                self._storeLoadError = error
                self._storeLoadSettled = true
                continuations = self._storeLoadContinuations
                self._storeLoadContinuations = []
                self.lock.unlock()
                for continuation in continuations {
                    continuation.resume()
                }
                return
            }
            // store 装载完成后再配置主上下文：此时无进行中的装载，
            // setter 不会同步等待 CoreData 内部队列（构建线程也不持任何锁）
            container.viewContext.automaticallyMergesChangesFromParent = true
            container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            self._storeLoaded = true
            self._storeLoadSettled = true
            continuations = self._storeLoadContinuations
            self._storeLoadContinuations = []
            self.lock.unlock()
            for continuation in continuations {
                continuation.resume()
            }
        }

        return container
    }

    // MARK: - 存储装载与冲突恢复

    private nonisolated static let recoveryLogger = Logger(subsystem: "com.holo.app", category: "CoreDataRecovery")

    /// 装载 store；遇到模型指纹冲突（App 与小组件等扩展进程各自编译的模型分叉、
    /// 或跨版本迁移映射缺失）时，把打不开的库文件整体改名备份后重建空库再试一次。
    /// 背景：共享库位于 App Group，多进程都可写；指纹不一致会随进程先后随机出现，
    /// 直接 fatalError 即「随机启动闪退」（2026-09-27 模拟器实锤）。
    /// 备份保留在原目录可人工救援；云端有 CloudKit 副本，空库重建后可回同步。
    nonisolated static func loadStoreAllowingRecovery(
        _ container: NSPersistentContainer,
        logger: Logger,
        onFinish: @escaping (Error?) -> Void
    ) {
        container.loadPersistentStores { _, error in
            guard let error, isModelMismatch(error) else {
                onFinish(error)
                return
            }

            let nsError = error as NSError
            let storeURL = container.persistentStoreDescriptions.first?.url
            // R02（2026-10-04 体检）：备份完整性是重建的硬前提——三件套没挪干净
            // （目录权限/空间异常/未合并 WAL/扩展并发访问）就重建空库，会永久丢失
            // 未合并事务。此时放弃自动重建，走可恢复失败状态，原库原地保留待救援。
            let backup = storeURL.map { backupIncompatibleStoreFiles(at: $0, logger: logger) }
                ?? ConflictBackupResult()
            guard backup.isComplete else {
                logger.fault("冲突库备份不完整（main=\(backup.hasMainFile, privacy: .public)，failed=\(backup.failedFiles.joined(separator: ","), privacy: .public)），放弃自动重建以保护原数据")
                onFinish(error)
                return
            }
            logger.fault("存储与当前模型不匹配(code \(nsError.code))，已完整备份冲突库，重建空库重试。userInfo: \(nsError.userInfo)")

            container.loadPersistentStores { _, retryError in
                if let retryError {
                    logger.fault("重建空库后仍装载失败：\(retryError.localizedDescription, privacy: .public)")
                    onFinish(retryError)
                    return
                }
                logger.notice("存储冲突恢复完成，已重建空库（旧库保留为备份）")
                // D03（2026-10-04 体检）：恢复事件落标记，主 App 启动时据此向用户
                // 说明「发生了什么 + 旧数据在哪」——空库静默当正常成功是信任事故
                recordConflictRecoveryMarker(storeURL: storeURL, backup: backup, logger: logger)
                onFinish(nil)
            }
        }
    }

    /// 是否属于「模型指纹/迁移映射」失败族（134100 不兼容哈希、134130 找不到源模型、映射不匹配等）
    nonisolated static func isModelMismatch(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return (134100...134199).contains(nsError.code)
    }

    /// 冲突库备份结果（R02，2026-10-04 体检）：三件套各自的搬运结果必须完整上报。
    /// 主文件挪走而 WAL/SHM 落下时，未合并事务随旧文件丢失——只有全部成功才算
    /// 完整备份，才允许重建空库。
    struct ConflictBackupResult: Equatable {
        var movedFileURLs: [URL] = []
        var failedFiles: [String] = []
        var hasMainFile = false

        var isComplete: Bool { hasMainFile && failedFiles.isEmpty }
    }

    /// 把打不开的库三件套（sqlite/-wal/-shm）改名备份，返回逐文件结果。
    /// 备份名带时间戳，多次冲突各自留底互不覆盖。
    nonisolated static func backupIncompatibleStoreFiles(at url: URL, logger: Logger) -> ConflictBackupResult {
        let fm = FileManager.default
        let stamp = Self.backupTimestampFormatter.string(from: Date())
        var result = ConflictBackupResult()
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let name = source.lastPathComponent
            let backup = source.deletingLastPathComponent()
                .appendingPathComponent(name + ".conflict-backup-" + stamp)
            do {
                try fm.moveItem(at: source, to: backup)
                result.movedFileURLs.append(backup)
                if suffix.isEmpty { result.hasMainFile = true }
            } catch {
                result.failedFiles.append(source.lastPathComponent)
                logger.error("备份 \(source.lastPathComponent, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    private nonisolated static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - 冲突恢复用户可见状态（D03，2026-10-04 体检）

    /// 冲突恢复事件：发生时间 + 备份文件路径。落库目录内的标记文件（App Group 共享，
    /// 主 App / 扩展进程谁触发恢复都能记录）；用户确认后删除标记。
    struct ConflictRecoveryEvent: Equatable {
        let occurredAt: Date
        let backupFileURLs: [URL]
    }

    private nonisolated static var conflictRecoveryMarkerURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return container.appendingPathComponent("store-conflict-recovery.json", isDirectory: false)
    }

    nonisolated static func pendingConflictRecoveryEvent() -> ConflictRecoveryEvent? {
        guard let url = conflictRecoveryMarkerURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MarkerPayload.self, from: data) else { return nil }
        let fm = FileManager.default
        let backups = decoded.backupFileNames
            .map { url.deletingLastPathComponent().appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        return ConflictRecoveryEvent(occurredAt: decoded.occurredAt, backupFileURLs: backups)
    }

    /// 用户已知晓恢复事件（看过说明/导出过备份）后清除标记
    nonisolated static func acknowledgeConflictRecovery() {
        guard let url = conflictRecoveryMarkerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 落恢复标记：备份清单直接来自本次备份结果——R02 修复旧实现的目录前缀扫描
    /// （`store.sqlite.conflict-backup-` 前缀匹配不到 `-wal`/`-shm` 备份，
    /// 导出清单会漏掉 WAL 中尚未合并的内容）。
    private nonisolated static func recordConflictRecoveryMarker(storeURL: URL?, backup: ConflictBackupResult, logger: Logger) {
        guard let storeURL, let markerURL = conflictRecoveryMarkerURL else {
            logger.error("冲突恢复标记写入失败：无法定位标记路径")
            return
        }
        let payload = MarkerPayload(
            occurredAt: Date(),
            backupFileNames: backup.movedFileURLs.map(\.lastPathComponent)
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            logger.error("冲突恢复标记写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private struct MarkerPayload: Codable {
        let occurredAt: Date
        let backupFileNames: [String]
    }

    /// 全进程唯一数据模型实例：真栈与测试栈必须共享同一份 NSManagedObjectModel。
    /// 多份实例（即使内容完全相同）会让 NSManagedObject 子类→实体映射出现全局歧义，
    /// 装载次数一多即触发系统层「模型不兼容 134020」——fetch 失败被 try? 吞成 nil 的假失败
    /// （2026-09-16/17 测试域三轮复发，R4-1 B 政策完全体；生产仅 buildContainer 调一次，行为不变）。
    private static let sharedDataModel: NSManagedObjectModel = CoreDataStack.shared.makeDataModel()

    nonisolated func createDataModel() -> NSManagedObjectModel {
        Self.sharedDataModel
    }

    /// 通过代码创建 Core Data 数据模型（仅由 sharedDataModel 惰性初始化调用一次）
    /// - Returns: NSManagedObjectModel
    private nonisolated func makeDataModel() -> NSManagedObjectModel {
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
        entities.append(createUserPreferenceEntity())
        entities.append(createUserAvatarEntity())
        // 分类学习（映射 + 归纳规则）：原先只存 UserDefaults，卸载即丢，迁入同步实体
        entities.append(createCategoryMappingRecordEntity())
        entities.append(createCategoryInductionRuleEntity())
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
        entities.append(contentsOf: CoreDataStack.createScheduleEntities())
        // 回收站清空批次（数据清理功能）
        entities.append(contentsOf: createRecycleBinEntities())
        // Matter「进行中的事」四实体（ID 逻辑外键、无跨域关系）
        entities.append(contentsOf: createMatterEntities())
        // 任务「分步推进」三实体（ID 逻辑外键、无跨域关系；2026-09-25 实施规格 §7.2）
        entities.append(contentsOf: createTaskExecutionEntities())
        // 目标共创会话与决策版本（ID 逻辑外键；payload 版本化信封）
        entities.append(contentsOf: createGoalWorkshopEntities())
        model.entities = entities
        return model
    }

    // MARK: - Store 位置（App Group 共享区）

    /// App Group 标识（与小组件等扩展共享的数据区，须与 entitlements 一致）
    private static let appGroupIdentifier = "group.com.tangyuxuan.holo-app"

    /// 数据库应处的位置：App Group 共享区（小组件等扩展进程可直接读写）
    nonisolated static var sharedStoreURL: URL {
        if let groupRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return groupRoot.appendingPathComponent("HoloDataModel.sqlite")
        }
        // App Group 不可用的环境（部分单元测试宿主）：退回旧沙盒路径
        return URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")
    }

    /// 1.0.3 之前的旧位置（沙盒 Documents），升级用户的数据仍在那里
    nonisolated static var legacyStoreURL: URL {
        URL.documentsDirectory.appendingPathComponent("HoloDataModel.sqlite")
    }

    /// 决定本次装载用哪个库：
    /// 共享区已有库 → 直接用；旧址有库 → 先整体搬进共享区（失败留在旧址，绝不落到空库）；
    /// 两处都无 → 全新安装，直接在共享区建库。
    nonisolated static func resolveStoreURLForMigration(model: NSManagedObjectModel) -> URL {
        let fm = FileManager.default
        let newURL = sharedStoreURL
        let oldURL = legacyStoreURL
        guard newURL != oldURL else { return newURL }

        if fm.fileExists(atPath: newURL.path) { return newURL }
        guard fm.fileExists(atPath: oldURL.path) else {
            try? fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return newURL
        }

        do {
            try migrateStore(at: oldURL, to: newURL, model: model)
            // 旧文件原地保留，作为本次搬家的回退底稿（后续版本再清理）
            return newURL
        } catch {
            return oldURL
        }
    }

    /// 搬迁整个 SQLite 存储，保留 CloudKit 映射及记录身份。
    /// migratePersistentStore 会重建对象身份，导致云端原记录再次导入形成副本。
    nonisolated static func migrateStore(at oldURL: URL, to newURL: URL, model: NSManagedObjectModel) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mover = NSPersistentStoreCoordinator(managedObjectModel: model)
        try mover.replacePersistentStore(
            at: newURL,
            destinationOptions: nil,
            withPersistentStoreFrom: oldURL,
            sourceOptions: [NSReadOnlyPersistentStoreOption: true],
            type: .sqlite
        )
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
    /// 若 store 已加载则立即返回；否则挂起当前协程直到 loadPersistentStores 完成。
    /// R01（2026-10-04 体检）：失败也是终态——等待方会被唤醒而不是永久挂起；
    /// 失败原因经 storeLoadError() 查询，由恢复门如实展示。
    func waitUntilReady() async {
        prepareIfNeeded()

        let didLoad = lock.withLock {
            _storeLoaded
        }
        if didLoad {
            return
        }
        // 失败终态：不再挂起，让调用方尽快继续（随后各自暴露失败状态）
        let settled = lock.withLock {
            _storeLoadSettled
        }
        if settled {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if _storeLoaded || _storeLoadSettled {
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

    /// 存储加载失败原因（R01）；nil = 成功或尚未到终态。恢复门据此向用户说明。
    nonisolated func storeLoadError() -> Error? {
        lock.withLock { _storeLoadError }
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
