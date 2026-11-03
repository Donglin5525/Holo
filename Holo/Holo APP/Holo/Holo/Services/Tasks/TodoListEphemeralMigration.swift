//
//  TodoListEphemeralMigration.swift
//  Holo
//
//  存量清空清单一次性归档（2026-10-11 一次性清单退场机制）
//
//  - 存量清单没有来源记录，无法区分长期/一次性；「有已完成任务且已无
//    未完成任务」的清单显然是做完的一次性项目，统一归档收尾
//  - 从未有任务的空清单不收（可能是用户手建还没启用的长期清单）
//  - 归档可恢复、不删任何任务记录；恢复即转长期（unarchiveList）
//  - 常驻退场规则（reconcileEphemeralLists）只收 isEphemeral 清单，本迁移
//    不分来源，故不幂等——UserDefaults once 标记只跑一次；失败下次重试
//

import Foundation
import CoreData
import os.log

nonisolated enum TodoListEphemeralMigration {

    private static let onceKey = "todoList.emptiedArchiveMigration.v1"
    private static let logger = Logger(subsystem: "com.holo.app", category: "TodoListEphemeralMigration")

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: onceKey) else { return }
        Task.detached(priority: .utility) {
            let stack = CoreDataStack.shared
            // 懒加载容器必须由主线程先建立（与 TaskExecutionMigration 同因：
            // 后台抢跑懒加载会与主线程等锁互锁，ABBA 死锁实锤在档）
            await MainActor.run { _ = stack.persistentContainer }
            await stack.waitUntilReady()
            do {
                let archived: Int = try await stack.performBackgroundTask { context in
                    try archiveEmptiedLists(in: context)
                }
                defaults.set(true, forKey: onceKey)
                if archived > 0 {
                    Self.logger.log("存量清空清单归档完成：\(archived) 个")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
                    }
                }
            } catch {
                Self.logger.error("存量清空清单归档失败（下次启动重试）：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// internal：单测直调（runIfNeeded 走后台等库链路，测试不便注入）
    static func archiveEmptiedLists(in context: NSManagedObjectContext) throws -> Int {
        let request = TodoList.fetchRequest()
        request.predicate = NSPredicate(format: "archived == NO AND deletedAt == nil")
        let lists = try context.fetch(request)
        var archived = 0
        for list in lists where !list.hasIncompleteTasks && list.hasCompletedTasks {
            list.archived = true
            list.updatedAt = Date()
            archived += 1
        }
        if archived > 0 {
            try context.save()
        }
        return archived
    }
}
