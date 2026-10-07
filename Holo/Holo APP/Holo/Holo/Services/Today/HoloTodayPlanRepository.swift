//
//  HoloTodayPlanRepository.swift
//  Holo
//
//  「今天减负」当日计划只读仓库（2026-10-03 实施方案 §8.1/§8.4）
//
//  - 只读：版本图（heads 计算）、幂等回执查询、引用事实批量取齐；
//  - HoloTodayPlanService 是唯一写入口，本仓库不做任何写入；
//  - context 注入：生产用 viewContext，测试用共享内存容器；
//  - 区分 noPlan / active / conflict / syncing / unavailable 五态，
//    syncing 不得被当作空计划回退基础列表（§8.4）。
//

import Foundation
import CoreData

nonisolated final class HoloTodayPlanRepository {

    /// 版本行的纯值投影（不外泄 NSManagedObject）。
    nonisolated struct RevisionRow: Equatable, Sendable {
        let id: UUID
        let operationID: String
        let command: String
        let parentRevisionIDs: [UUID]
        let payload: HoloTodayPlanPayload
        let payloadDigest: String
        let createdAt: Date
        let createdTaskID: UUID?
        let restoredFromRevisionID: UUID?
    }

    private let context: NSManagedObjectContext

    nonisolated init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - 版本图

    /// 读取 scope 内全部有效版本（软删剔除、按 operationID+digest 去重）。
    /// 相同 operationID 不同 digest 或不可解析 payload → 整体不可用（返回 nil + 原因）。
    nonisolated func revisions(scopeKey: String) -> (rows: [RevisionRow]?, unavailableReason: String?) {
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        request.predicate = NSPredicate(format: "scopeKey == %@ AND deletedAt == nil", scopeKey)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        let fetched: [HoloTodayPlanRevision]
        do {
            fetched = try context.fetch(request)
        } catch {
            return (nil, "fetchFailed: \(error.localizedDescription)")
        }

        var byID: [UUID: RevisionRow] = [:]
        var operationIndex: [String: RevisionRow] = [:]
        for row in fetched where !row.isPlaceholder {
            guard row.schemaVersion == Int16(HoloTodayPlanPayload.schemaVersion) else {
                return (nil, "unsupportedSchemaVersion(\(row.schemaVersion))")
            }
            guard let data = row.payloadJSON.data(using: .utf8),
                  let payload = try? HoloTodayPlanPayload.decode(from: data) else {
                return (nil, "invalidPayloadJSON")
            }
            let projected = RevisionRow(
                id: row.id,
                operationID: row.operationID,
                command: row.commandRaw,
                parentRevisionIDs: row.parentRevisionIDs,
                payload: payload,
                payloadDigest: row.payloadDigest,
                createdAt: row.createdAt,
                createdTaskID: row.createdTaskID,
                restoredFromRevisionID: row.restoredFromRevisionID
            )
            if let existing = operationIndex[row.operationID] {
                if existing.payloadDigest != projected.payloadDigest {
                    // 同 operationID 不同 digest：数据损坏，不能任选一份（§7.3）
                    return (nil, "operationIDDigestConflict(\(row.operationID))")
                }
                continue
            }
            operationIndex[row.operationID] = projected
            byID[row.id] = projected
        }

        let ordered = byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        return (ordered, nil)
    }

    /// heads：未被任何其他版本列为父的版本（§8.4）。
    nonisolated func heads(of rows: [RevisionRow]) -> [RevisionRow] {
        var parentIDs = Set<UUID>()
        for row in rows {
            parentIDs.formUnion(row.parentRevisionIDs)
        }
        return rows.filter { !parentIDs.contains($0.id) }
    }

    /// 父版本缺失检测（CloudKit 分批到达期间；§8.4 syncing 判据之一）。
    nonisolated func hasMissingParents(_ rows: [RevisionRow]) -> Bool {
        let ids = Set(rows.map(\.id))
        return rows.contains { row in
            !row.parentRevisionIDs.allSatisfy { ids.contains($0) }
        }
    }

    // MARK: - 当前计划读取（五态）

    nonisolated func currentPlan(scope: HoloTodayDayScope) -> HoloTodayPlanRead {
        let (rowsOrNil, unavailableReason) = revisions(scopeKey: scope.scopeKey)
        guard let rows = rowsOrNil else {
            return HoloTodayPlanRead(scope: scope, state: .unavailable(reason: unavailableReason ?? "unknown"))
        }
        if rows.isEmpty {
            return HoloTodayPlanRead(scope: scope, state: .noPlan)
        }
        if hasMissingParents(rows) {
            return HoloTodayPlanRead(scope: scope, state: .syncing(reason: "missingParentRevisions"))
        }

        let headRows = heads(of: rows)
        if headRows.isEmpty {
            // 理论不可达（heads 至少一）；防御为 syncing 而非空态。
            return HoloTodayPlanRead(scope: scope, state: .syncing(reason: "noReachableHead"))
        }
        if headRows.count > 1 {
            let candidates = headRows
                .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
                .map {
                    HoloTodayPlanConflictCandidate(
                        revisionID: $0.id,
                        payload: $0.payload,
                        createdAt: $0.createdAt,
                        command: $0.command
                    )
                }
            return HoloTodayPlanRead(scope: scope, state: .conflict(candidates: candidates))
        }

        let head = headRows[0]
        // 引用到齐检查：任务/步骤缺失（行不存在）→ syncing；已删/已归档 → 读取端自然剔除，不算 syncing。
        let missing = missingReferenceTaskIDs(in: head.payload)
        if !missing.isEmpty {
            return HoloTodayPlanRead(scope: scope, state: .syncing(reason: "missingTaskReferences(\(missing.count))"))
        }
        return HoloTodayPlanRead(
            scope: scope,
            state: .active(payload: head.payload, headRevisionIDs: [head.id])
        )
    }

    /// 幂等回执查询：同 operationID 的既有版本（跨 scope 查询）。
    nonisolated func revision(operationID: String) -> RevisionRow? {
        let request = NSFetchRequest<HoloTodayPlanRevision>(entityName: "HoloTodayPlanRevision")
        request.predicate = NSPredicate(
            format: "operationID == %@ AND deletedAt == nil AND id != %@",
            operationID,
            HoloTodayPlanSchemaDefaults.zeroUUID as CVarArg
        )
        request.fetchLimit = 2
        let fetched = (try? context.fetch(request)) ?? []
        guard let first = fetched.first else { return nil }
        guard let data = first.payloadJSON.data(using: .utf8),
              let payload = try? HoloTodayPlanPayload.decode(from: data) else { return nil }
        return RevisionRow(
            id: first.id,
            operationID: first.operationID,
            command: first.commandRaw,
            parentRevisionIDs: first.parentRevisionIDs,
            payload: payload,
            payloadDigest: first.payloadDigest,
            createdAt: first.createdAt,
            createdTaskID: first.createdTaskID,
            restoredFromRevisionID: first.restoredFromRevisionID
        )
    }

    // MARK: - 引用事实

    /// payload 引用的任务里「行完全不存在」的 ID（与已删除行区分；§8.4）。
    nonisolated func missingReferenceTaskIDs(in payload: HoloTodayPlanPayload) -> [UUID] {
        var ids = Set(payload.entries.map(\.taskID))
        ids.formUnion(payload.deferredTaskIDs)
        ids.formUnion(payload.confirmedMustTaskIDs)
        return fetchExistingTaskIDs(ids).missing
    }

    /// 批量取任务与步骤事实（写入校验与读投影共用；一次查询，禁止逐行查库）。
    nonisolated func facts(taskIDs: Set<UUID>, stepIDs: Set<UUID>) -> HoloTodayReliefPolicy.Facts {
        var taskFacts: [UUID: HoloTodayReliefPolicy.TaskFact] = [:]
        var stepFacts: [UUID: HoloTodayReliefPolicy.StepFact] = [:]

        if !taskIDs.isEmpty {
            let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
            request.predicate = NSPredicate(format: "id IN %@", taskIDs)
            if let tasks = try? context.fetch(request) {
                for task in tasks {
                    taskFacts[task.id] = HoloTodayReliefPolicy.TaskFact(
                        id: task.id,
                        title: task.title,
                        dueDate: task.dueDate,
                        isAllDay: task.isAllDay,
                        completed: task.completed,
                        visible: task.deletedAt == nil && !task.archived
                    )
                }
            }
        }
        if !stepIDs.isEmpty {
            let request = NSFetchRequest<HoloTaskExecutionStep>(entityName: "HoloTaskExecutionStep")
            request.predicate = NSPredicate(format: "id IN %@", stepIDs)
            if let steps = try? context.fetch(request) {
                for step in steps {
                    stepFacts[step.id] = HoloTodayReliefPolicy.StepFact(
                        id: step.id,
                        taskID: step.taskID,
                        actionText: step.actionText,
                        doneWhen: step.doneWhen,
                        stateRaw: step.stateRaw,
                        originRevisionID: step.originRevisionID
                    )
                }
            }
        }
        return HoloTodayReliefPolicy.Facts(tasks: taskFacts, steps: stepFacts)
    }

    /// 当前（基础）列表中可灵活推进的任务：今日到期 + 近期无日期（§8.1 首次手动放下继承范围）。
    /// 逾期不进 entries（真实期限仍在约束区展示）。
    nonisolated func flexibleBaseTaskIDs(scope: HoloTodayDayScope) -> [UUID] {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "completed == false"),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "archived == false"),
            NSPredicate(format: "isDailyRitual == false"),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "dueDate >= %@ AND dueDate < %@", scope.dayStart as NSDate, scope.dayEnd as NSDate),
                NSPredicate(format: "dueDate == nil"),
            ]),
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "dueDate", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        let tasks = (try? context.fetch(request)) ?? []
        return DuplicateRowFilter.deduplicatingCopies(tasks).map(\.id)
    }

    /// 库是否真的空（可见任务 0；检索失败不是空库，返回 nil）。
    nonisolated func visibleTaskCount() -> Int? {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "deletedAt == nil AND archived == false")
        return (try? context.count(for: request))
    }

    // MARK: - 私有

    nonisolated private func fetchExistingTaskIDs(_ ids: Set<UUID>) -> (existing: Set<UUID>, missing: [UUID]) {
        guard !ids.isEmpty else { return ([], []) }
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id IN %@", ids)
        request.returnsObjectsAsFaults = true
        let tasks = (try? context.fetch(request)) ?? []
        let existing = Set(tasks.map(\.id))
        return (existing, ids.subtracting(existing).sorted { $0.uuidString < $1.uuidString })
    }
}
