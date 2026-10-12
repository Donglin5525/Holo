//
//  TaskExecutionMigration.swift
//  Holo
//
//  存量分步推进数据一次性迁移（2026-10-11 拆开瘦身）
//
//  - executionSchemaVersion >= 1 的任务：活动版本的执行步骤转成子任务（CheckItem）
//    done → 已勾选；waiting → 带等待态（含等待语/提醒时间）；引用既有清单项的步骤 →
//    不建第二份，等待态回写到被引用的 CheckItem 上
//  - 转完清 executionSchemaVersion / activeExecutionRevisionID；
//    旧三实体（Revision/Step/Receipt）行原地残留、不再被读
//  - 幂等：无接管任务时零开销返回（不设 once 标记，清除即完成态）；
//    App 启动后台等库就绪后跑，失败下次启动重试
//

import Foundation
import CoreData
import os.log

nonisolated enum TaskExecutionMigration {

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskExecutionMigration")

    static func runIfNeeded() {
        Task.detached(priority: .utility) {
            let stack = CoreDataStack.shared
            // 懒加载容器必须由主线程先建立：buildContainer 内含对主队列的
            // performBlockAndWait，后台线程抢跑初始化会与主线程等懒加载锁互锁（ABBA 死锁）
            await MainActor.run { _ = stack.persistentContainer }
            await stack.waitUntilReady()
            do {
                let migrated: Int = try await stack.performBackgroundTask { context in
                    try migrateAll(in: context)
                }
                if migrated > 0 {
                    Self.logger.log("分步推进迁移完成：\(migrated) 个任务已转为子任务清单")
                    NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
                }
            } catch {
                Self.logger.error("分步推进迁移失败（下次启动重试）：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 批量

    /// internal：单测直调（runIfNeeded 走后台等库链路，测试不便注入）
    static func migrateAll(in context: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "executionSchemaVersion >= 1")
        let managed = try context.fetch(request)
        guard !managed.isEmpty else { return 0 }

        var migrated = 0
        for task in managed {
            do {
                try migrate(task: task, in: context)
                migrated += 1
            } catch {
                logger.error("任务 \(task.id.uuidString, privacy: .public) 迁移失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        return migrated
    }

    // MARK: - 单任务

    private static func migrate(task: TodoTask, in context: NSManagedObjectContext) throws {
        let steps = activeRevisionSteps(task: task, in: context)
        let existingItems = (task.checkItems?.allObjects as? [CheckItem] ?? [])
            .sorted { $0.order < $1.order }
        var maxOrder = existingItems.map(\.order).max() ?? -1

        for step in steps {
            // 引用既有清单项的步骤：不建第二份 completed/标题，只回写等待态
            if step.kindRaw == HoloTaskExecutionStepKind.sourceCheckItemReference.rawValue,
               let refID = step.sourceCheckItemID,
               let target = existingItems.first(where: { $0.id == refID }) {
                if step.stateRaw == "waiting", !target.isChecked {
                    target.isWaiting = true
                    target.waitNote = step.waitReason
                    target.reviewRemindAt = step.reviewAfter
                }
                continue
            }
            guard step.kindRaw == HoloTaskExecutionStepKind.action.rawValue,
                  let title = step.actionText, !title.isEmpty else { continue }

            maxOrder += 1
            let item = CheckItem.create(
                in: context,
                title: title,
                task: task,
                order: maxOrder,
                isWaiting: step.stateRaw == "waiting",
                waitNote: step.stateRaw == "waiting" ? step.waitReason : nil,
                waitHints: []
            )
            item.isChecked = step.stateRaw == "done"
            item.createdAt = step.createdAt
            if step.stateRaw == "waiting" {
                item.reviewRemindAt = step.reviewAfter
            }
        }

        task.executionSchemaVersion = 0
        task.activeExecutionRevisionID = nil
        task.updatedAt = Date()
        try context.save()
    }

    /// 活动版本的步骤（按创建顺序 = 提案顺序）。无 activeExecutionRevisionID 标记的
    /// 极旧数据，按「最新创建的版本」兜底；完全没有步骤时返回空（只清标记位）。
    private static func activeRevisionSteps(task: TodoTask, in context: NSManagedObjectContext) -> [HoloTaskExecutionStep] {
        let request = NSFetchRequest<HoloTaskExecutionStep>(entityName: "HoloTaskExecutionStep")
        request.predicate = NSPredicate(format: "taskID == %@ AND deletedAt == nil", task.id as CVarArg)
        let all = (try? context.fetch(request)) ?? []
        guard !all.isEmpty else { return [] }

        let revisionID: UUID
        if let active = task.activeExecutionRevisionID {
            revisionID = active
        } else {
            // 兜底：取步骤里最新创建的那一版
            let latest = all.max { $0.createdAt < $1.createdAt }
            revisionID = latest?.originRevisionID ?? task.id
        }
        return all
            .filter { $0.originRevisionID == revisionID }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
