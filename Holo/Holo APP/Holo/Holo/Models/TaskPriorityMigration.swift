//
//  TaskPriorityMigration.swift
//  Holo
//
//  旧优先级 → 轻重缓急两轴 一次性迁移（2026-10-06 东林拍板：放弃旧优先级逻辑，
//  全 App 单一分类体系）。App target 专用（依赖 DuplicateRowFilter，小组件不编译本文件）。
//  2026-10-07 P 档体系映射（raw 完全兼容 10-06 版迁移结果，无需重跑）。
//

import Foundation
import CoreData

// MARK: - 旧优先级 → 两轴 一次性迁移（2026-10-06 东林拍板：放弃旧优先级逻辑，全 App 单一体系）

/// 映射规则（简单迁移，重要性判断权仍归用户）：
/// 十分紧急 → P1＋手动 P1；高 → P1＋按日期；中 → 暂未判断（进待整理，用连续整理判断）；
/// 低 → P3＋按日期。迁移幂等：只写与目标值有差异的行，重复执行零写入。
/// （10-06 版已迁移设备的落库值 重要=1/手动紧急=1/不重要=2 与本版 P1/P1/P3 同 raw，零重跑。）
enum TaskPriorityMigration {

    static let migrationFlagKey = "taskExperienceV2.priorityMigrated.v1"

    static func map(_ priority: TaskPriority) -> (importance: TaskImportance, urgencyMode: TaskUrgencyMode) {
        switch priority {
        case .urgent: return (.p1, .p1)
        case .high: return (.p1, .auto)
        case .medium: return (.unknown, .auto)
        case .low: return (.p3, .auto)
        }
    }

    /// 启动一次性入口：按设备 UserDefaults 标记只跑一次（双设备各自跑，值级幂等）
    @MainActor
    static func runIfNeeded(in context: NSManagedObjectContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        _ = run(in: context)
        defaults.set(true, forKey: migrationFlagKey)
    }

    /// 迁移本体：同 id 多行只写物理行号最小的规范行；仅改有差异的任务；
    /// 不动已删除任务（恢复后按其保存的分类走，不再回头改）。
    @discardableResult
    @MainActor
    static func run(in context: NSManagedObjectContext) -> Int {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        guard let rows = try? context.fetch(request), !rows.isEmpty else { return 0 }
        var changed = 0
        for task in DuplicateRowFilter.deduplicatingCopies(rows) {
            let target = map(task.taskPriority)
            if task.importance != target.importance || task.urgencyMode != target.urgencyMode {
                task.importance = target.importance
                task.urgencyMode = target.urgencyMode
                task.updatedAt = Date()
                changed += 1
            }
        }
        guard changed > 0, (try? context.save()) != nil else { return changed }
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
        return changed
    }
}
