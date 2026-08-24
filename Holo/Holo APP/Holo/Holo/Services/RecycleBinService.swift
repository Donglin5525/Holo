//
//  RecycleBinService.swift
//  Holo
//
//  数据清理与回收站核心服务
//
//  职责：
//  - 模块清空 / 清空所有数据：创建批次并打软删标记（deletedAt + deletedBatchId）
//  - 回收站批次列表（按删除事件分组展示）
//  - 立即清除批次（物理删除 + 附件文件清理 + 通知取消）
//  - 30 天过期清理（App 启动维护）
//  - 旧软删标记（isSoftDeleted/deletedFlag 无时间戳）一次性迁移
//  - 各模块数据概览统计
//
//  恢复与冲突预检见 RecycleBinRestoreEngine.swift。
//  方案文档：docs/plans/2026-08-24-data-cleanup-recycle-bin-plan.md
//

import Foundation
import CoreData
import Combine
import UserNotifications
import OSLog

// MARK: - 模块定义

/// 参与数据清理的模块（健康不参与：只读 HealthKit 不落库）
enum RecycleBinModule: String, CaseIterable, Identifiable {
    case finance
    case thought
    case task
    case habit
    case anniversary
    case goal
    case chat
    case insight
    case memory
    case lifePlan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .finance: return "财务"
        case .thought: return "想法"
        case .task: return "任务"
        case .habit: return "习惯"
        case .anniversary: return "纪念日"
        case .goal: return "目标"
        case .chat: return "聊天记录"
        case .insight: return "AI 报告"
        case .memory: return "长期记忆"
        case .lifePlan: return "周计划"
        }
    }

    /// 该模块清空时打标记的主库实体名（不含跟随父对象生命周期的子实体）
    var entityNames: [String] {
        switch self {
        case .finance:
            // finance 的分档由 FinanceClearScope 决定，这里返回全部；分档时由调用方裁剪
            return ["Transaction", "Account", "Category", "Budget", "SpendingProject"]
        case .thought:
            return ["Thought", "ThoughtTag", "Topic"]
        case .task:
            return ["TodoTask", "TodoList", "TodoFolder", "TodoTag"]
        case .habit:
            return ["Habit", "HabitRecord"]
        case .anniversary:
            return ["Anniversary"]
        case .goal:
            return ["Goal", "GoalMetricLog"]
        case .chat:
            return ["ChatMessage"]
        case .insight:
            return ["MemoryInsight", "MemoryInsightFeedback"]
        case .memory:
            return ["HoloMemoryRecordMO", "HoloMemoryEvidenceMO", "HoloMemoryAnchorAliasMO",
                    "HoloMemoryObservationRunMO", "HoloMemoryTombstoneMO"]
        case .lifePlan:
            return ["LifePlanMO", "PlanPriorityMO", "PlanActionMO", "PlanSignalMO",
                    "PlanFeedbackMO", "PlanRunMO"]
        }
    }

    /// 「清空所有数据」时是否包含该模块
    static let globalClearModules: Set<RecycleBinModule> = [.finance, .thought, .task, .habit,
                                                            .anniversary, .goal, .chat, .insight,
                                                            .memory, .lifePlan]
}

/// 财务清空分档（东林拍板 D1：清空前咨询用户删减范围）
enum FinanceClearScope: String, CaseIterable, Identifiable {
    /// 仅清交易记录（保留账户/分类/预算/固定支出设置）
    case transactionsOnly
    /// 清空全部财务数据
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transactionsOnly: return "仅清空交易记录"
        case .all: return "清空全部财务数据"
        }
    }

    var entityNames: [String] {
        switch self {
        case .transactionsOnly: return ["Transaction"]
        case .all: return RecycleBinModule.finance.entityNames
        }
    }
}

// MARK: - 批次信息（UI 模型）

struct RecycleBinBatchInfo: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let isGlobalScope: Bool
    let modules: [RecycleBinModule]
    let summary: String?
    /// 各模块在批次内的实时条数
    var moduleCounts: [RecycleBinModule: Int] = [:]
    /// 批次内剩余总条数
    var totalRemaining: Int { moduleCounts.values.reduce(0, +) }

    /// 回收站保留期（30 天）
    static let retentionDays = 30

    var daysRemaining: Int {
        let elapsed = Date().timeIntervalSince(createdAt)
        let days = Int(ceil(elapsed / 86400))
        return max(0, Self.retentionDays - days)
    }

    var isExpired: Bool { daysRemaining <= 0 }
}

// MARK: - Service

@MainActor
final class RecycleBinService: ObservableObject {

    static let shared = RecycleBinService()

    private let logger = Logger(subsystem: "com.holo.app", category: "RecycleBin")

    /// 回收站批次列表（按删除时间倒序）
    @Published private(set) var batches: [RecycleBinBatchInfo] = []

    /// 旧标记迁移的 UserDefaults 开关
    private static let legacyMigrationKey = "recycleBin.legacySoftDeleteMigrated.v1"

    private init() {}

    // MARK: - 清空请求

    struct ClearRequest {
        var modules: Set<RecycleBinModule>
        /// 仅 modules 含 finance 时有效；nil 视为 .all
        var financeScope: FinanceClearScope?
        var summary: String?
    }

    /// 各模块「将被清空」的条数预览（确认页展示用）
    func previewCounts(for modules: Set<RecycleBinModule>, financeScope: FinanceClearScope?) async -> [RecycleBinModule: Int] {
        var result: [RecycleBinModule: Int] = [:]
        for module in modules.sorted(by: { $0.rawValue < $1.rawValue }) {
            let names = Self.resolvedEntityNames(module: module, financeScope: modules.contains(.finance) ? (financeScope ?? .all) : nil)
            var count = 0
            for name in names {
                count += Self.countAlive(entityName: name, in: CoreDataStack.shared.persistentContainer)
            }
            if module == .memory {
                count += await Self.sensitiveMemoryCount()
            }
            result[module] = count
        }
        return result
    }

    /// 执行清空：创建批次 + 打软删标记，返回批次 ID。
    /// 只处理正常状态数据（deletedAt == nil）；已在回收站/已软删的数据保持原批次不动。
    func performClear(_ request: ClearRequest, now: Date = Date()) async throws -> UUID {
        let modules = request.modules.intersection(RecycleBinModule.globalClearModules)
        guard !modules.isEmpty else {
            throw RecycleBinError.emptyClearRequest
        }
        let financeScope = request.financeScope ?? .all
        let batchId = UUID()
        // 单一模块=module；多模块（清空所有数据）=global
        let scopeValue = modules.count == 1 ? "module" : "global"

        // 1. 主库打标记（含批次记录创建）
        let taskIdsNeedingNotificationCancel: [UUID] = try await CoreDataStack.shared.performBackgroundTask { context in
            let batch = RecycleBinBatch(context: context)
            batch.id = batchId
            batch.createdAt = now
            batch.scope = scopeValue
            batch.modules = modules.map(\.rawValue).sorted().joined(separator: ",")
            batch.summary = request.summary ?? Self.defaultSummary(modules: modules, financeScope: modules.contains(.finance) ? financeScope : nil)

            var cancelledTaskIds: [UUID] = []
            for module in modules.sorted(by: { $0.rawValue < $1.rawValue }) {
                let entityNames = Self.resolvedEntityNames(module: module, financeScope: modules.contains(.finance) ? financeScope : nil)
                for entityName in entityNames {
                    if module == .task && entityName == "TodoTask" {
                        cancelledTaskIds = try Self.fetchAliveIDs(entityName: entityName, context: context)
                    }
                    try Self.markAllDeleted(entityName: entityName, batchId: batchId, at: now, context: context)
                }
            }
            try context.save()
            return cancelledTaskIds
        }

        // 2. 敏感记忆库（memory 模块）
        if modules.contains(.memory) {
            try await Self.clearSensitiveMemory(batchId: batchId, now: now)
            try await Self.resetSensitiveControlState()
        }

        // 3. 任务模块：批量取消待发提醒
        if !taskIdsNeedingNotificationCancel.isEmpty {
            Self.cancelTaskNotifications(taskIds: taskIdsNeedingNotificationCancel)
        }

        // 4. 广播各模块刷新 + 记忆系统缓存失效
        Self.broadcastDataChange(for: modules)

        await reloadBatches()
        logger.info("清空完成：\(self.loggerSummary(modules)) 批次 \(batchId.uuidString)")
        return batchId
    }

    // MARK: - 批次列表

    func reloadBatches() async {
        // 敏感库计数是独立 context，先在协程里查好再传进后台闭包（闭包内不能 await）
        var sensitiveCounts: [UUID: Int] = [:]
        let rawBatchIds: [UUID] = (try? await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<RecycleBinBatch>(entityName: "RecycleBinBatch")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request).map(\.id)
        }) ?? []
        for batchId in rawBatchIds {
            sensitiveCounts[batchId] = await Self.sensitiveMemoryCountInBatch(batchId: batchId)
        }

        let infos: [RecycleBinBatchInfo] = (try? await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<RecycleBinBatch>(entityName: "RecycleBinBatch")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            let rawBatches = try context.fetch(request)
            return rawBatches.map { batch -> RecycleBinBatchInfo in
                var info = RecycleBinBatchInfo(
                    id: batch.id,
                    createdAt: batch.createdAt,
                    isGlobalScope: batch.scope == "global",
                    modules: batch.moduleList.compactMap { RecycleBinModule(rawValue: $0) },
                    summary: batch.summary
                )
                for module in info.modules {
                    var count = 0
                    for entityName in module.entityNames {
                        count += Self.countInBatch(entityName: entityName, batchId: batch.id, in: context)
                    }
                    if module == .memory {
                        count += sensitiveCounts[batch.id] ?? 0
                    }
                    info.moduleCounts[module] = count
                }
                return info
            }
        }) ?? []
        batches = infos.filter { $0.totalRemaining > 0 || $0.moduleCounts.isEmpty }
    }

    // MARK: - 立即清除（物理删除）

    /// 立即清除指定批次（不等 30 天）
    func purgeBatch(_ batchId: UUID, now: Date = Date()) async throws {
        _ = try await Self.purgeEntities(matching: NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg), modules: nil, batchIds: [batchId])
        await reloadBatches()
    }

    /// 清空整个回收站
    func purgeAll(now: Date = Date()) async throws {
        let allBatchIds = batches.map(\.id)
        _ = try await Self.purgeEntities(matching: NSPredicate(format: "deletedBatchId != nil"), modules: nil, batchIds: allBatchIds)
        await reloadBatches()
    }

    // MARK: - 30 天过期清理（启动维护）

    /// 清理所有超过保留期的软删数据（含批次删除与单条软删）
    @discardableResult
    func purgeExpired(now: Date = Date()) async -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(RecycleBinBatchInfo.retentionDays) * 86400)
        do {
            let removed = try await Self.purgeEntities(matching: NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate), modules: nil, batchIds: [])
            if removed > 0 {
                logger.info("回收站过期清理：物理删除 \(removed) 个对象")
                await reloadBatches()
            }
            return removed
        } catch {
            logger.error("回收站过期清理失败：\(error.localizedDescription)")
            return 0
        }
    }

    /// App 启动维护入口（HoloApp 启动链调用）
    func performStartupMaintenance() async {
        migrateLegacySoftDeletesIfNeeded()
        await purgeExpired()
    }

    // MARK: - 旧标记一次性迁移

    /// 旧版无时间戳的软删标记（Thought/Anniversary isSoftDeleted、TodoTask/TodoTag deletedFlag 无 deletedAt）
    /// 迁移到统一 deletedAt（按单条软删语义，无批次、不可恢复、30 天后物理清理）
    func migrateLegacySoftDeletesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return }

        let context = CoreDataStack.shared.viewContext
        var migrated = 0
        let legacyTargets: [(entityName: String, legacyFlagKey: String)] = [
            ("Thought", "isSoftDeleted"),
            ("Anniversary", "isSoftDeleted"),
            ("TodoTask", "deletedFlag"),
            ("TodoTag", "deletedFlag"),
        ]
        for target in legacyTargets {
            let request = NSFetchRequest<NSManagedObject>(entityName: target.entityName)
            request.predicate = NSPredicate(format: "%K == YES AND deletedAt == nil", target.legacyFlagKey)
            let objects = (try? context.fetch(request)) ?? []
            let now = Date()
            for object in objects {
                (object as? SoftDeletable)?.markDeleted(batchId: nil, at: now)
                migrated += 1
            }
        }
        if context.hasChanges {
            try? context.save()
        }
        defaults.set(true, forKey: Self.legacyMigrationKey)
        if migrated > 0 {
            logger.info("旧软删标记迁移完成：\(migrated) 条")
        }
    }

    // MARK: - 数据概览（设置页数据管理）

    /// 各模块正常状态条数
    func moduleDataCounts() async -> [RecycleBinModule: Int] {
        var result: [RecycleBinModule: Int] = [:]
        for module in RecycleBinModule.allCases {
            var count = 0
            for name in module.entityNames {
                count += Self.countAlive(entityName: name, in: CoreDataStack.shared.persistentContainer)
            }
            if module == .memory {
                count += await Self.sensitiveMemoryCount()
            }
            result[module] = count
        }
        return result
    }

    // MARK: - 物理删除核心

    /// 物理删除匹配谓词的软删对象，并连带清理附件文件、取消任务通知、删除空批次
    static func purgeEntities(matching predicate: NSPredicate, modules: Set<RecycleBinModule>?, batchIds: [UUID]) async throws -> Int {
        // 先收集附件/通知所需的轻量信息，再删对象
        struct PurgePlan {
            var taskAttachmentIds: [UUID] = []
            var thoughtAttachmentIds: [UUID] = []
            var taskNotificationIds: [UUID] = []
            var count = 0
        }

        let plan: PurgePlan = try await CoreDataStack.shared.performBackgroundTask { context in
            var p = PurgePlan()
            for entityName in allSoftDeletableEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = predicate
                request.includesSubentities = false
                switch entityName {
                case "TodoTask":
                    let tasks = try context.fetch(request) as? [TodoTask] ?? []
                    p.taskNotificationIds = tasks.map(\.id)
                    p.count += tasks.count
                case "Thought":
                    let thoughts = try context.fetch(request) as? [Thought] ?? []
                    p.thoughtAttachmentIds = thoughts.map(\.id)
                    p.count += thoughts.count
                default:
                    p.count += try context.count(for: request)
                }
            }

            // 执行删除（逐实体 fetch + delete，CloudKit 镜像依赖 context save）
            for entityName in allSoftDeletableEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = predicate
                request.includesSubentities = false
                let objects = try context.fetch(request)
                for (index, object) in objects.enumerated() {
                    context.delete(object)
                    if (index + 1) % 500 == 0 {
                        try context.save()
                    }
                }
            }
            try context.save()
            return p
        }

        // 磁盘附件清理（对象删除后）
        if !plan.taskAttachmentIds.isEmpty {
            AttachmentFileManager.deleteAttachmentDirectories(for: plan.taskAttachmentIds)
        }
        for thoughtId in plan.thoughtAttachmentIds {
            AttachmentFileManager.deleteAllAttachments(for: thoughtId)
        }
        // 任务通知取消
        if !plan.taskNotificationIds.isEmpty {
            cancelTaskNotifications(taskIds: plan.taskNotificationIds)
        }
        // 敏感库同步清理（谓词口径一致）
        try await purgeSensitiveMemory(matching: predicate)

        // 空批次自删
        try await deleteEmptyBatches(batchIds: batchIds)
        return plan.count
    }

    /// 物理删除全部软删实体名清单（与 SoftDeletable.swift 声明保持一致）
    static let allSoftDeletableEntityNames: [String] = [
        "Transaction", "Account", "Category", "Budget", "SpendingProject",
        "Thought", "ThoughtTag", "Topic",
        "TodoTask", "TodoList", "TodoFolder", "TodoTag",
        "Habit", "HabitRecord",
        "Anniversary",
        "Goal", "GoalMetricLog",
        "ChatMessage",
        "MemoryInsight", "MemoryInsightFeedback",
        "HoloMemoryRecordMO", "HoloMemoryEvidenceMO", "HoloMemoryAnchorAliasMO",
        "HoloMemoryObservationRunMO", "HoloMemoryTombstoneMO",
        "LifePlanMO", "PlanPriorityMO", "PlanActionMO", "PlanSignalMO",
        "PlanFeedbackMO", "PlanRunMO",
    ]

    // MARK: - 内部工具

    private static func resolvedEntityNames(module: RecycleBinModule, financeScope: FinanceClearScope?) -> [String] {
        if module == .finance, let scope = financeScope {
            return scope.entityNames
        }
        return module.entityNames
    }

    private static func defaultSummary(modules: Set<RecycleBinModule>, financeScope: FinanceClearScope?) -> String {
        if modules == RecycleBinModule.globalClearModules {
            return "清空所有数据"
        }
        if modules.count == 1, let only = modules.first {
            if only == .finance, let scope = financeScope {
                return "清空财务数据 · \(scope == .transactionsOnly ? "仅交易" : "全部")"
            }
            return "清空\(only.displayName)数据"
        }
        return "清空 " + modules.map(\.displayName).joined(separator: "、")
    }

    /// 批量打软删标记（只处理 deletedAt == nil 的正常数据），分批 save 控制内存
    static func markAllDeleted(entityName: String, batchId: UUID, at date: Date, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.includesSubentities = false
        let objects = try context.fetch(request)
        var pendingSave = 0
        for object in objects {
            guard let softDeletable = object as? SoftDeletable else { continue }
            softDeletable.markDeleted(batchId: batchId, at: date)
            pendingSave += 1
            if pendingSave >= 500 {
                try context.save()
                pendingSave = 0
            }
        }
        if pendingSave > 0 {
            try context.save()
        }
    }

    static func fetchAliveIDs(entityName: String, context: NSManagedObjectContext) throws -> [UUID] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        let results = try context.fetch(request) as? [[String: Any]] ?? []
        return results.compactMap { $0["id"] as? UUID }
    }

    static func countAlive(entityName: String, in container: NSPersistentContainer) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedAt == nil")
        return (try? container.viewContext.count(for: request)) ?? 0
    }

    static func countInBatch(entityName: String, batchId: UUID, in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
        return (try? context.count(for: request)) ?? 0
    }

    /// 批量取消任务待发提醒（通知 id 前缀 = task.id.uuidString）
    static func cancelTaskNotifications(taskIds: [UUID]) {
        guard !taskIds.isEmpty else { return }
        let prefixes = Set(taskIds.map(\.uuidString))
        Task {
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let identifiers = requests
                .map(\.identifier)
                .filter { identifier in
                    guard let separator = identifier.firstIndex(of: "-") else { return false }
                    return prefixes.contains(String(identifier[identifier.startIndex..<separator]))
                }
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private static func deleteEmptyBatches(batchIds: [UUID]) async throws {
        // 敏感库计数先在协程里查好（闭包内不能 await）
        var sensitiveCounts: [UUID: Int] = [:]
        if batchIds.isEmpty {
            let allIds: [UUID] = (try? await CoreDataStack.shared.performBackgroundTask { context in
                let request = NSFetchRequest<RecycleBinBatch>(entityName: "RecycleBinBatch")
                return try context.fetch(request).map(\.id)
            }) ?? []
            for id in allIds {
                sensitiveCounts[id] = await sensitiveMemoryCountInBatch(batchId: id)
            }
        } else {
            for id in batchIds {
                sensitiveCounts[id] = await sensitiveMemoryCountInBatch(batchId: id)
            }
        }

        _ = try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<RecycleBinBatch>(entityName: "RecycleBinBatch")
            if batchIds.isEmpty {
                request.predicate = NSPredicate(value: true)
            } else {
                request.predicate = NSPredicate(format: "id IN %@", batchIds)
            }
            let batches = try context.fetch(request)
            var hasChanges = false
            for batch in batches {
                let hasRemaining = allSoftDeletableEntityNames.contains { entityName in
                    countInBatch(entityName: entityName, batchId: batch.id, in: context) > 0
                } || (sensitiveCounts[batch.id] ?? 0) > 0
                if !hasRemaining {
                    context.delete(batch)
                    hasChanges = true
                }
            }
            if hasChanges {
                try context.save()
            }
        }
    }

    /// 广播各模块数据变更通知（UI 刷新）
    static func broadcastDataChange(for modules: Set<RecycleBinModule>) {
        let center = NotificationCenter.default
        if modules.contains(.finance) { center.post(name: .financeDataDidChange, object: nil) }
        if modules.contains(.task) { center.post(name: .todoDataDidChange, object: nil) }
        if modules.contains(.habit) { center.post(name: .habitDataDidChange, object: nil) }
        if modules.contains(.thought) { center.post(name: .thoughtDataDidChange, object: nil) }
        if modules.contains(.anniversary) { center.post(name: .anniversaryDataDidChange, object: nil) }
        if modules.contains(.goal) { center.post(name: .goalDataDidChange, object: nil) }
        if modules.contains(.chat) {
            // 聊天页常驻且直接绑定仓库 @Published 数组，外部清空/恢复后须重载内存
            ChatMessageRepository.shared.loadMessages()
        }
    }

    private func loggerSummary(_ modules: Set<RecycleBinModule>) -> String {
        modules.map(\.rawValue).sorted().joined(separator: ",")
    }
}

// MARK: - 敏感记忆库操作

extension RecycleBinService {

    /// 敏感记忆库的批量打标记
    private static func clearSensitiveMemory(batchId: UUID, now: Date) async throws {
        guard let context = await sensitiveMemoryContext() else { return }
        try await context.perform {
            for entityName in RecycleBinModule.memory.entityNames {
                try markAllDeleted(entityName: entityName, batchId: batchId, at: now, context: context)
            }
        }
    }

    /// 敏感库 ControlState 为全局运行状态单例：清空所有数据时物理重置（运行期自动重建）
    private static func resetSensitiveControlState() async throws {
        guard let context = await sensitiveMemoryContext() else { return }
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HoloMemoryControlStateMO")
            for object in try context.fetch(request) {
                context.delete(object)
            }
            try context.save()
        }
    }

    static func purgeSensitiveMemory(matching predicate: NSPredicate) async throws {
        guard let context = await sensitiveMemoryContext() else { return }
        try await context.perform {
            for entityName in RecycleBinModule.memory.entityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = predicate
                for object in try context.fetch(request) {
                    context.delete(object)
                }
            }
            try context.save()
        }
    }

    static func sensitiveMemoryCount() async -> Int {
        guard let context = await sensitiveMemoryContext() else { return 0 }
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "deletedAt == nil")
            return (try? context.count(for: request)) ?? 0
        }
    }

    static func sensitiveMemoryCountInBatch(batchId: UUID) async -> Int {
        guard let context = await sensitiveMemoryContext() else { return 0 }
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
            return (try? context.count(for: request)) ?? 0
        }
    }

    static func sensitiveMemoryContext() async -> NSManagedObjectContext? {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return nil }
        return await repository.sensitiveBackgroundContext()
    }
}

// MARK: - 错误

enum RecycleBinError: LocalizedError {
    case emptyClearRequest
    case batchNotFound

    var errorDescription: String? {
        switch self {
        case .emptyClearRequest: return "清空请求未包含任何有效模块"
        case .batchNotFound: return "回收站批次不存在或已被清除"
        }
    }
}
