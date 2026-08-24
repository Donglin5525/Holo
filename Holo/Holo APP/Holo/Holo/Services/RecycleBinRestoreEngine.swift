//
//  RecycleBinRestoreEngine.swift
//  Holo
//
//  回收站恢复流程：冲突预检 + 批量/单条恢复 + 依赖联动
//
//  冲突规则（方案 §7）：
//  - 软删除下同 id 唯一，无主键冲突；冲突只发生在「内容撞车」——
//    删除后用户重新记了/导入了相似数据。
//  - 指纹判定按模块：财务复用导入去重指纹（日期|金额|类型|分类|账户），
//    任务=标题+截止日，习惯=名字+类型，想法=内容全文。
//  - 疑似重复默认跳过（保留现有数据），预览页可强制恢复。
//
//  联动规则：恢复子对象时若其同模块父对象仍处于软删状态（如交易的账户、
//  打卡记录的习惯、任务的清单），一并恢复父对象。
//

import Foundation
import CoreData
import OSLog

// MARK: - 恢复数据模型

struct RestoreConflictItem: Identifiable, Equatable {
    /// 回收站对象的 id（恢复时据此跳过）
    let id: UUID
    let module: RecycleBinModule
    /// 回收站侧摘要
    let title: String
    let detail: String
    /// 现有数据侧摘要（撞车的对象）
    let existingDetail: String
}

struct RestorePreviewReport {
    var restorableCount = 0
    var conflicts: [RestoreConflictItem] = []
    var totalInBatch: Int { restorableCount + conflicts.count }
    var hasConflicts: Bool { !conflicts.isEmpty }
}

struct RestoreOutcomeReport {
    var restored = 0
    var skippedConflicts = 0
    var linkedRestored = 0
}

// MARK: - Service Extension

extension RecycleBinService {

    // MARK: 冲突预检

    /// 恢复预览：统计无冲突条数 + 列出与现有数据疑似重复的条目
    func restorePreview(batchId: UUID, moduleFilter: RecycleBinModule? = nil) async throws -> RestorePreviewReport {
        guard let batch = findBatch(id: batchId) else { throw RecycleBinError.batchNotFound }
        let modules = moduleFilter.map { [$0] } ?? batch.modules
        var report = RestorePreviewReport()

        for module in modules {
            let entityNames = RecycleBinModule.entityNamesForRestore(module: module)
            for entityName in entityNames {
                let trashed = try fetchBatchObjects(entityName: entityName, batchId: batchId)
                switch entityName {
                case "Transaction":
                    let existingFingerprints = try existingTransactionFingerprints()
                    for transaction in trashed as? [Transaction] ?? [] {
                        guard let fingerprint = DataImportService.makeFingerprint(from: transaction) else {
                            report.restorableCount += 1
                            continue
                        }
                        if existingFingerprints.contains(fingerprint) {
                            report.conflicts.append(RestoreConflictItem(
                                id: transaction.id, module: module,
                                title: transaction.note ?? transaction.type,
                                detail: Self.transactionSummary(transaction),
                                existingDetail: "已存在同日同额同分类的交易"
                            ))
                        } else {
                            report.restorableCount += 1
                        }
                    }
                case "TodoTask":
                    let existingKeys = try existingTaskKeys()
                    for task in trashed as? [TodoTask] ?? [] {
                        let key = Self.taskKey(title: task.title, dueDate: task.dueDate)
                        if existingKeys.contains(key) {
                            report.conflicts.append(RestoreConflictItem(
                                id: task.id, module: module,
                                title: task.title,
                                detail: Self.taskSummary(task),
                                existingDetail: "已存在同名同截止日的任务"
                            ))
                        } else {
                            report.restorableCount += 1
                        }
                    }
                case "Habit":
                    let existingKeys = try existingHabitKeys()
                    for habit in trashed as? [Habit] ?? [] {
                        let key = "\(habit.name.trimmed)|\(habit.type)"
                        if existingKeys.contains(key) {
                            report.conflicts.append(RestoreConflictItem(
                                id: habit.id, module: module,
                                title: habit.name,
                                detail: "习惯 · \(habit.type == 0 ? "打卡型" : "数值型")",
                                existingDetail: "已存在同名习惯"
                            ))
                        } else {
                            report.restorableCount += 1
                        }
                    }
                case "Thought":
                    let existingContents = try existingThoughtContents()
                    for thought in trashed as? [Thought] ?? [] {
                        let content = thought.content.trimmed
                        if existingContents.contains(content) {
                            report.conflicts.append(RestoreConflictItem(
                                id: thought.id, module: module,
                                title: String(content.prefix(24)),
                                detail: "想法 · \(thought.createdAt.formatted(.dateTime.month().day()))",
                                existingDetail: "已存在相同内容的想法"
                            ))
                        } else {
                            report.restorableCount += 1
                        }
                    }
                default:
                    report.restorableCount += trashed.count
                }
            }
        }
        return report
    }

    // MARK: 恢复执行

    /// 恢复批次（整批或按模块）。跳过冲突 id（预览页用户默认跳过、可改判强制恢复）。
    @discardableResult
    func restoreBatch(batchId: UUID,
                      skipConflictIds: Set<UUID> = [],
                      moduleFilter: RecycleBinModule? = nil) async throws -> RestoreOutcomeReport {
        guard let batch = findBatch(id: batchId) else { throw RecycleBinError.batchNotFound }
        let modules = moduleFilter.map { [$0] } ?? batch.modules
        var outcome = RestoreOutcomeReport()

        let restoredTaskIDs: [UUID] = try await CoreDataStack.shared.performBackgroundTask { context in
            var taskIDs: [UUID] = []
            for module in modules {
                for entityName in RecycleBinModule.entityNamesForRestore(module: module) {
                    let objects = try Self.fetchBatchObjects(entityName: entityName, batchId: batchId, in: context)
                    for object in objects {
                        guard let softDeletable = object as? SoftDeletable,
                              let id = object.value(forKey: "id") as? UUID else { continue }
                        if skipConflictIds.contains(id) {
                            outcome.skippedConflicts += 1
                            continue
                        }
                        softDeletable.clearDeletedMark()
                        outcome.restored += 1
                        if entityName == "TodoTask" {
                            taskIDs.append(id)
                        }
                        // 同模块父对象联动恢复
                        outcome.linkedRestored += Self.restoreLinkedParents(of: object, in: context)
                    }
                }
            }
            try context.save()
            return taskIDs
        }

        // 记忆模块：敏感库同批恢复
        if modules.contains(.memory) {
            try await restoreSensitiveMemory(batchId: batchId)
        }

        // 任务恢复后重排提醒通知
        await rescheduleTaskNotifications(taskIDs: restoredTaskIDs)

        Self.broadcastDataChange(for: Set(modules))
        await reloadBatches()
        return outcome
    }

    /// 单条恢复（含联动父对象）
    @discardableResult
    func restoreSingleObject(id: UUID, entityName: String, module: RecycleBinModule) async throws -> RestoreOutcomeReport {
        var outcome = RestoreOutcomeReport()
        let restoredTaskIDs: [UUID] = try await CoreDataStack.shared.performBackgroundTask { context in
            var taskIDs: [UUID] = []
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt != nil", id as CVarArg)
            request.fetchLimit = 1
            if let object = try context.fetch(request).first {
                (object as? SoftDeletable)?.clearDeletedMark()
                outcome.restored += 1
                outcome.linkedRestored += Self.restoreLinkedParents(of: object, in: context)
                if entityName == "TodoTask" {
                    taskIDs.append(id)
                }
                try context.save()
            }
            return taskIDs
        }
        await rescheduleTaskNotifications(taskIDs: restoredTaskIDs)
        Self.broadcastDataChange(for: [module])
        await reloadBatches()
        return outcome
    }

    // MARK: 联动恢复

    /// 恢复子对象时，若其同模块父对象仍处于软删状态则一并恢复（返回联动恢复数量）
    static func restoreLinkedParents(of object: NSManagedObject, in context: NSManagedObjectContext) -> Int {
        var restored = 0

        func restoreIfDeleted(_ parent: NSManagedObject?) {
            guard let parent,
                  let softDeletable = parent as? SoftDeletable,
                  softDeletable.deletedAt != nil else { return }
            softDeletable.clearDeletedMark()
            restored += 1
        }

        switch object {
        case let transaction as Transaction:
            restoreIfDeleted(transaction.account)
            restoreIfDeleted(transaction.category)
        case let record as HabitRecord:
            restoreIfDeleted(record.habit)
        case let task as TodoTask:
            // 清单为容器（同模块），联动恢复；goal/sourceThought 跨模块不联动（查询层已过滤兜底）
            restoreIfDeleted(task.list)
        default:
            break
        }
        return restored
    }

    // MARK: 内部工具

    private func findBatch(id: UUID) -> RecycleBinBatchInfo? {
        batches.first { $0.id == id }
    }

    private func fetchBatchObjects(entityName: String, batchId: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
        return try CoreDataStack.shared.viewContext.fetch(request)
    }

    static func fetchBatchObjects(entityName: String, batchId: UUID, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
        return try context.fetch(request)
    }

    /// 现有（未删除）交易的指纹集合
    private func existingTransactionFingerprints() throws -> Set<String> {
        let request = NSFetchRequest<Transaction>(entityName: "Transaction")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = try CoreDataStack.shared.viewContext.fetch(request)
        var fingerprints = Set<String>()
        for transaction in existing {
            if let fingerprint = DataImportService.makeFingerprint(from: transaction) {
                fingerprints.insert(fingerprint)
            }
        }
        return fingerprints
    }

    private func existingTaskKeys() throws -> Set<String> {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = try CoreDataStack.shared.viewContext.fetch(request)
        return Set(existing.map { Self.taskKey(title: $0.title, dueDate: $0.dueDate) })
    }

    private func existingHabitKeys() throws -> Set<String> {
        let request = NSFetchRequest<Habit>(entityName: "Habit")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = try CoreDataStack.shared.viewContext.fetch(request)
        return Set(existing.map { "\($0.name.trimmed)|\($0.type)" })
    }

    private func existingThoughtContents() throws -> Set<String> {
        let request = NSFetchRequest<Thought>(entityName: "Thought")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = try CoreDataStack.shared.viewContext.fetch(request)
        return Set(existing.map { $0.content.trimmed })
    }

    private static func taskKey(title: String, dueDate: Date?) -> String {
        let dayStamp: String
        if let dueDate {
            dayStamp = dueDate.formatted(.dateTime.year().month().day())
        } else {
            dayStamp = "-"
        }
        return "\(title.trimmed)|\(dayStamp)"
    }

    private static func transactionSummary(_ transaction: Transaction) -> String {
        let amount = transaction.amount as Decimal
        let day = transaction.date.formatted(.dateTime.month().day())
        let categoryName = transaction.category?.name ?? "未分类"
        let typeText = transaction.type == "income" ? "收入" : "支出"
        return "\(typeText) ¥\(amount) · \(day) · \(categoryName)"
    }

    private static func taskSummary(_ task: TodoTask) -> String {
        if let dueDate = task.dueDate {
            return "截止 \(dueDate.formatted(.dateTime.month().day()))"
        }
        return "无截止日"
    }

    /// 恢复后重排任务提醒（主线程 fetch 恢复的任务，逐个调度）
    private func rescheduleTaskNotifications(taskIDs: [UUID]) async {
        guard !taskIDs.isEmpty else { return }
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id IN %@ AND deletedAt == nil", taskIDs)
        let tasks = (try? context.fetch(request)) ?? []
        for task in tasks where !task.completed {
            TodoNotificationService.shared.scheduleReminders(for: task)
        }
    }

    /// 敏感记忆库同批恢复
    private func restoreSensitiveMemory(batchId: UUID) async throws {
        guard let context = await Self.sensitiveMemoryContext() else { return }
        try await context.perform {
            for entityName in RecycleBinModule.memory.entityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
                for object in try context.fetch(request) {
                    (object as? SoftDeletable)?.clearDeletedMark()
                }
            }
            try context.save()
        }
    }
}

// MARK: - 模块恢复实体映射

extension RecycleBinModule {

    /// 恢复时逐实体处理的顺序无关紧要（软删=清标记，关系未断）；
    /// 该清单与 entityNames 一致，独立方法便于恢复侧单独调整
    static func entityNamesForRestore(module: RecycleBinModule) -> [String] {
        module.entityNames
    }
}

// MARK: - String 便捷

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
