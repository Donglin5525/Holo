//
//  HoloTodayPlanService.swift
//  Holo
//
//  「今天减负」当日计划唯一写入口（2026-10-03 实施方案 §8）
//
//  - actor 隔离 = 全局串行计划写队列（本机两处同时覆盖的防线）；
//  - 事务顺序（§8.1）：幂等回执 → scope 过期 → heads 校验 → 结构/引用校验 →
//    无变化不写 → 一次 context.save()（失败 rollback）→ 广播 holoTodayPlanDidChange；
//  - 全成或全不成：空库新任务与计划版本同一次保存；
//  - 不把主上下文托管对象跨队列传入：后台 context 内重建全部事实。
//

import Foundation
import CoreData

nonisolated actor HoloTodayPlanService {

    nonisolated static let shared = HoloTodayPlanService(container: CoreDataStack.shared.persistentContainer)

    private let container: NSPersistentContainer

    nonisolated init(container: NSPersistentContainer) {
        self.container = container
    }

    // MARK: - 命令（§8.1 接口责任）

    /// 采用审阅候选（AI 或手动审阅产出；editedPayload 为用户在审阅内的调整）。
    nonisolated func adopt(
        candidate: HoloTodayPlanCandidate,
        editedPayload: HoloTodayPlanPayload?,
        expectedHeads: [UUID],
        operationID: String,
        currentSourceFingerprint: String? = nil
    ) async throws -> HoloTodayPlanReceipt {
        let finalPayload = editedPayload ?? candidate.payload
        // 来源指纹校验（AI 路径冻结指纹；手动路径传 nil 跳过、由载荷引用校验兜底）
        if let current = currentSourceFingerprint, !current.isEmpty,
           candidate.sourceFingerprint != current {
            throw HoloTodayPlanError.staleSource("fingerprintChanged")
        }
        // 空库创建时最终 payload 会注入新任务条目，与候选 payload 必然不同：
        // 幂等比较只能按 operationID 重放，不带 intendedDigest。
        let intendedDigest: String? = candidate.newTaskTitle == nil ? (try? finalPayload.digest()) : nil
        return try await writeRevision(
            scope: candidate.scope,
            operationID: operationID,
            command: .adopt,
            payload: finalPayload,
            expectedHeads: expectedHeads,
            createTaskTitle: candidate.newTaskTitle,
            restoredFromRevisionID: nil,
            intendedDigest: intendedDigest
        )
    }

    /// 手动加入今日：无显式计划时以该任务为选择起点；有计划时从完整 payload 修改一项。
    nonisolated func addTask(
        taskID: UUID,
        goal: HoloTodayGoal,
        scope: HoloTodayDayScope,
        expectedHeads: [UUID],
        operationID: String
    ) async throws -> HoloTodayPlanReceipt {
        try await modify(scope: scope, operationID: operationID, command: .manualAdd, expectedHeads: expectedHeads) { base, repository in
            if let base {
                return (base.withEntry(HoloTodaySelectionEntry(taskID: taskID, goal: goal)), nil)
            }
            let payload = HoloTodayPlanPayload(
                selectionMode: .explicit,
                entries: [HoloTodaySelectionEntry(taskID: taskID, goal: goal)]
            )
            _ = repository
            return (payload, nil)
        }
    }

    /// 手动放下：首次操作仅继承基础列表中可灵活推进的任务（逾期留在约束区）。
    nonisolated func deferTask(
        taskID: UUID,
        acknowledgement: HoloTodayDeadlineAcknowledgement?,
        scope: HoloTodayDayScope,
        expectedHeads: [UUID],
        operationID: String
    ) async throws -> HoloTodayPlanReceipt {
        try await modify(scope: scope, operationID: operationID, command: .manualDefer, expectedHeads: expectedHeads) { base, repository in
            if let base {
                return (base.deferring(taskID: taskID, acknowledgement: acknowledgement), nil)
            }
            // 首次手动放下：继承基础可灵活任务（今日到期+无日期），移除目标；逾期不进 entries
            let inherited = repository.flexibleBaseTaskIDs(scope: scope)
                .filter { $0 != taskID }
                .map { HoloTodaySelectionEntry(taskID: $0, goal: .taskResult) }
            let payload = HoloTodayPlanPayload(
                selectionMode: .explicit,
                entries: inherited,
                deferredTaskIDs: [taskID],
                deadlineAcknowledgements: acknowledgement.map { [$0] } ?? []
            )
            return (payload, nil)
        }
    }

    /// 更换某任务当日目标（整件事 ↔ 已有步骤）。
    nonisolated func changeGoal(
        taskID: UUID,
        goal: HoloTodayGoal,
        scope: HoloTodayDayScope,
        expectedHeads: [UUID],
        operationID: String
    ) async throws -> HoloTodayPlanReceipt {
        try await modify(scope: scope, operationID: operationID, command: .manualGoal, expectedHeads: expectedHeads) { base, repository in
            guard let base, base.entry(for: taskID) != nil else {
                throw HoloTodayPlanError.invalidTarget("taskNotSelected(\(taskID.uuidString))")
            }
            _ = repository
            return (base.withEntry(HoloTodaySelectionEntry(taskID: taskID, goal: goal)), nil)
        }
    }

    /// 撤销：只有当前 head 对应目标版本时可撤销；复制采用前父 payload（无父 → inheritBase）。
    /// 撤销不删历史、不删除用户确认创建的根任务、不撤销后来发生的完成事实。
    nonisolated func undo(
        adoptedRevisionID: UUID,
        scope: HoloTodayDayScope,
        expectedHeads: [UUID],
        operationID: String
    ) async throws -> HoloTodayPlanReceipt {
        try await performWrite { context, repository in
            try self.precheck(context: context, repository: repository, scope: scope, operationID: operationID)

            let (rowsOrNil, unavailableReason) = repository.revisions(scopeKey: scope.scopeKey)
            guard let rows = rowsOrNil else {
                throw HoloTodayPlanError.unavailable(unavailableReason ?? "unknown")
            }
            let headRows = repository.heads(of: rows)
            let headIDs = Set(headRows.map(\.id))
            guard headIDs == Set(expectedHeads), headIDs == [adoptedRevisionID] else {
                // 用户后来又手动调整 → 旧回执的撤销失效，不能跨过新编辑强行覆盖（§8.3）
                throw HoloTodayPlanError.conflict("staleUndoTarget")
            }
            guard let head = headRows.first(where: { $0.id == adoptedRevisionID }) else {
                throw HoloTodayPlanError.conflict("undoTargetMissing")
            }

            // 复制采用前父版本 payload；无父版本（首次采用）→ 恢复基础状态
            let restorePayload: HoloTodayPlanPayload
            if let parentID = head.parentRevisionIDs.first,
               let parent = rows.first(where: { $0.id == parentID }) {
                restorePayload = parent.payload
            } else {
                restorePayload = .inheritBase
            }
            try HoloTodayReliefPolicy.validateStructure(restorePayload)

            let receipt = try self.commit(
                context: context,
                scope: scope,
                operationID: operationID,
                command: .undo,
                payload: restorePayload,
                parentIDs: headIDs.sorted { $0.uuidString < $1.uuidString },
                basePayload: head.payload,
                createdTask: nil,
                restoredFromRevisionID: adoptedRevisionID
            )
            return receipt
        }
    }

    /// 分叉解决：选择一份完整版本，parentIDs 覆盖当前全部 heads（§8.4）。
    nonisolated func resolveConflict(
        chosenPayload: HoloTodayPlanPayload,
        scope: HoloTodayDayScope,
        expectedHeads: [UUID],
        operationID: String
    ) async throws -> HoloTodayPlanReceipt {
        return try await writeRevision(
            scope: scope,
            operationID: operationID,
            command: .resolveConflict,
            payload: chosenPayload,
            expectedHeads: expectedHeads,
            createTaskTitle: nil,
            restoredFromRevisionID: nil,
            intendedDigest: try? chosenPayload.digest()
        )
    }

    // MARK: - 通用写入路径

    /// 手动单点修改：从当前完整 payload 修改一项（无显式计划时按命令语义建首份 payload）。
    nonisolated private func modify(
        scope: HoloTodayDayScope,
        operationID: String,
        command: HoloTodayPlanCommand,
        expectedHeads: [UUID],
        _ merge: @escaping (HoloTodayPlanPayload?, HoloTodayPlanRepository) throws -> (HoloTodayPlanPayload, String?)
    ) async throws -> HoloTodayPlanReceipt {
        try await performWrite { context, repository in
            try self.precheck(context: context, repository: repository, scope: scope, operationID: operationID)

            let (rowsOrNil, unavailableReason) = repository.revisions(scopeKey: scope.scopeKey)
            guard let rows = rowsOrNil else {
                throw HoloTodayPlanError.unavailable(unavailableReason ?? "unknown")
            }
            let headRows = repository.heads(of: rows)
            let headIDs = Set(headRows.map(\.id))
            guard headIDs == Set(expectedHeads) else {
                throw HoloTodayPlanError.conflict("headsChanged")
            }
            guard headRows.count <= 1 else {
                throw HoloTodayPlanError.conflict("forkUnresolved")
            }
            let basePayload = headRows.first?.payload

            let (payload, createTaskTitle) = try merge(basePayload, repository)

            return try self.writeValidatedRevision(
                context: context,
                repository: repository,
                scope: scope,
                operationID: operationID,
                command: command,
                payload: payload,
                headIDs: Array(headIDs),
                basePayload: basePayload,
                createTaskTitle: createTaskTitle,
                restoredFromRevisionID: nil
            )
        }
    }

    /// adopt / resolveConflict 的写入路径（含完整引用校验与空库建任务）。
    nonisolated private func writeRevision(
        scope: HoloTodayDayScope,
        operationID: String,
        command: HoloTodayPlanCommand,
        payload: HoloTodayPlanPayload,
        expectedHeads: [UUID],
        createTaskTitle: String?,
        restoredFromRevisionID: UUID?,
        intendedDigest: String? = nil
    ) async throws -> HoloTodayPlanReceipt {
        try await performWrite { context, repository in
            try self.precheck(
                context: context, repository: repository,
                scope: scope, operationID: operationID,
                intendedDigest: intendedDigest
            )

            let (rowsOrNil, unavailableReason) = repository.revisions(scopeKey: scope.scopeKey)
            guard let rows = rowsOrNil else {
                throw HoloTodayPlanError.unavailable(unavailableReason ?? "unknown")
            }
            let headRows = repository.heads(of: rows)
            let headIDs = Set(headRows.map(\.id))
            guard headIDs == Set(expectedHeads) else {
                throw HoloTodayPlanError.conflict("headsChanged")
            }
            if command == .resolveConflict {
                // 分叉解决必须发生在真实分叉上
                guard headRows.count >= 2 else {
                    throw HoloTodayPlanError.conflict("noForkToResolve")
                }
            } else {
                // 其余命令要求单 head；adopt 遇到未解决分叉必须先 resolveConflict
                guard headRows.count <= 1 else {
                    throw HoloTodayPlanError.conflict("forkUnresolved")
                }
            }
            let basePayload = headRows.first?.payload

            return try self.writeValidatedRevision(
                context: context,
                repository: repository,
                scope: scope,
                operationID: operationID,
                command: command,
                payload: payload,
                headIDs: Array(headIDs),
                basePayload: basePayload,
                createTaskTitle: createTaskTitle,
                restoredFromRevisionID: restoredFromRevisionID
            )
        }
    }

    // MARK: - 事务步骤（均在后台 context 内执行）

    /// 步骤 1-4：幂等回执、scope 过期检查。
    /// intendedDigest：调用方已知最终 payload 时传入（相同→重放同次结果；不同→冲突）。
    nonisolated private func precheck(
        context: NSManagedObjectContext,
        repository: HoloTodayPlanRepository,
        scope: HoloTodayDayScope,
        operationID: String,
        intendedDigest: String? = nil
    ) throws {
        guard !operationID.isEmpty else {
            throw HoloTodayPlanError.invalidTarget("emptyOperationID")
        }
        // 幂等：命中相同 operationID → 同次结果（不重复建对象；§5 不变式 5）
        if let existing = repository.revision(operationID: operationID) {
            if let intendedDigest, existing.payloadDigest != intendedDigest {
                // 相同 operationID 的不同 digest：不能任选一份（§7.3）
                throw HoloTodayPlanError.conflict("operationIDDigestMismatch")
            }
            throw HoloTodayPlanReplay(existing: existing)
        }
        // 跨午夜/时区变化：本 scope 不再接受写入（§7.1）
        guard scope.contains(Date()) else {
            throw HoloTodayPlanError.expiredDay(scope.scopeKey)
        }
    }

    /// 步骤 5-7：校验 → 无变化不写 → 一次保存。
    nonisolated private func writeValidatedRevision(
        context: NSManagedObjectContext,
        repository: HoloTodayPlanRepository,
        scope: HoloTodayDayScope,
        operationID: String,
        command: HoloTodayPlanCommand,
        payload: HoloTodayPlanPayload,
        headIDs: [UUID],
        basePayload: HoloTodayPlanPayload?,
        createTaskTitle: String?,
        restoredFromRevisionID: UUID?
    ) throws -> HoloTodayPlanReceipt {
        var finalPayload = payload
        var createdTask: TodoTask?

        // 空库创建（§8.2）：仅真空库 + 用户明确单一动作；一次保存内建根任务+版本
        if let title = createTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            guard repository.visibleTaskCount() == 0 else {
                throw HoloTodayPlanError.invalidTarget("libraryNotEmpty")
            }
            guard finalPayload.entries.isEmpty, finalPayload.deferredTaskIDs.isEmpty else {
                throw HoloTodayPlanError.invalidTarget("newTaskWithExistingSelection")
            }
            let task = TodoTask.create(in: context, title: title)
            createdTask = task
            finalPayload = HoloTodayPlanPayload(
                selectionMode: .explicit,
                entries: [HoloTodaySelectionEntry(taskID: task.id, goal: .taskResult)]
            )
        }

        do {
            try HoloTodayReliefPolicy.validateStructure(finalPayload)
        } catch let error as HoloTodayReliefPolicy.PayloadStructureError {
            throw HoloTodayPlanError.invalidTarget(String(describing: error))
        }

        // 引用事实批量取齐（含新任务）
        var taskIDs = Set(finalPayload.entries.map(\.taskID))
        taskIDs.formUnion(finalPayload.deferredTaskIDs)
        taskIDs.formUnion(finalPayload.confirmedMustTaskIDs)
        if let createdTask { taskIDs.insert(createdTask.id) }
        let stepIDs = Set(finalPayload.entries.compactMap { entry -> UUID? in
            if case .existingStep(let stepID, _, _) = entry.goal { return stepID }
            return nil
        })
        let facts = repository.facts(taskIDs: taskIDs, stepIDs: stepIDs)
        var enrichedFacts = facts
        if let createdTask {
            enrichedFacts = HoloTodayReliefPolicy.Facts(
                tasks: facts.tasks.merging([
                    createdTask.id: HoloTodayReliefPolicy.TaskFact(
                        id: createdTask.id,
                        title: createdTask.title,
                        dueDate: nil,
                        isAllDay: false,
                        completed: false,
                        visible: true
                    )
                ]) { current, _ in current },
                steps: facts.steps
            )
        }

        do {
            try HoloTodayReliefPolicy.validateReferences(finalPayload, facts: enrichedFacts, scope: scope)
        } catch let error as HoloTodayReliefPolicy.ValidationError {
            switch error {
            case .deadlineAcknowledgementRequired(let id):
                throw HoloTodayPlanError.acknowledgementRequired(id)
            default:
                throw HoloTodayPlanError.invalidTarget(String(describing: error))
            }
        }

        // 无变化：不写版本、不发成功保存回执（§5 不变式 4；§4.3「按原安排继续」）。
        // 分叉解决除外：用户在两个版本间做了决定，必须落一个 parentIDs 覆盖双方的新版本。
        if command != .resolveConflict, createdTask == nil, let basePayload, basePayload == finalPayload {
            return HoloTodayPlanReceipt(
                revisionID: headIDs.first,
                replayed: false,
                changed: false,
                changedTaskIDs: [],
                createdTaskID: nil,
                payload: finalPayload
            )
        }

        return try commit(
            context: context,
            scope: scope,
            operationID: operationID,
            command: command,
            payload: finalPayload,
            parentIDs: headIDs.sorted { $0.uuidString < $1.uuidString },
            basePayload: basePayload,
            createdTask: createdTask,
            restoredFromRevisionID: restoredFromRevisionID
        )
    }

    /// 落一条完整版本 + 可选新任务，一次 context.save()；失败 rollback。
    nonisolated private func commit(
        context: NSManagedObjectContext,
        scope: HoloTodayDayScope,
        operationID: String,
        command: HoloTodayPlanCommand,
        payload: HoloTodayPlanPayload,
        parentIDs: [UUID],
        basePayload: HoloTodayPlanPayload?,
        createdTask: TodoTask?,
        restoredFromRevisionID: UUID?
    ) throws -> HoloTodayPlanReceipt {
        let digest: String
        let payloadJSON: String
        do {
            let data = try payload.canonicalData()
            digest = try payload.digest()
            payloadJSON = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw HoloTodayPlanError.invalidTarget("payloadEncodeFailed")
        }
        guard !payloadJSON.isEmpty else {
            throw HoloTodayPlanError.invalidTarget("payloadEncodeFailed")
        }

        let revision = HoloTodayPlanRevision(context: context)
        revision.id = UUID()
        revision.schemaVersion = Int16(HoloTodayPlanPayload.schemaVersion)
        revision.scopeKey = scope.scopeKey
        revision.dateKey = scope.dateKey
        revision.timeZoneIdentifier = scope.timeZoneIdentifier
        revision.dayStart = scope.dayStart
        revision.dayEnd = scope.dayEnd
        let parentsData = (try? JSONEncoder().encode(parentIDs)) ?? Data()
        revision.parentRevisionIDsJSON = String(data: parentsData, encoding: .utf8) ?? "[]"
        revision.operationID = operationID
        revision.commandRaw = command.rawValue
        revision.payloadJSON = payloadJSON
        revision.payloadDigest = digest
        revision.createdAt = Date()
        revision.restoredFromRevisionID = restoredFromRevisionID
        revision.createdTaskID = createdTask?.id

        do {
            try context.save()
        } catch {
            context.rollback()
            throw HoloTodayPlanError.saveFailed(error.localizedDescription)
        }

        // 保存成功后才广播（§8.1 步骤 7）
        let scopeKey = scope.scopeKey
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .holoTodayPlanDidChange,
                object: nil,
                userInfo: ["scopeKey": scopeKey]
            )
        }

        let beforeTasks = Set((basePayload?.entries ?? []).map(\.taskID))
            .union(basePayload?.deferredTaskIDs ?? [])
        let afterTasks = Set(payload.entries.map(\.taskID))
            .union(payload.deferredTaskIDs)
        return HoloTodayPlanReceipt(
            revisionID: revision.id,
            replayed: false,
            changed: true,
            changedTaskIDs: beforeTasks.symmetricDifference(afterTasks).sorted { $0.uuidString < $1.uuidString },
            createdTaskID: createdTask?.id,
            payload: payload
        )
    }

    // MARK: - 后台事务执行

    nonisolated private func performWrite(
        _ block: @escaping (NSManagedObjectContext, HoloTodayPlanRepository) throws -> HoloTodayPlanReceipt
    ) async throws -> HoloTodayPlanReceipt {
        try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { context in
                let repository = HoloTodayPlanRepository(context: context)
                do {
                    let result = try block(context, repository)
                    continuation.resume(returning: result)
                } catch let replay as HoloTodayPlanReplay {
                    continuation.resume(returning: replay.receipt())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// 幂等重放信号：precheck 命中相同 operationID 时以「同次结果」完成本次调用。
nonisolated private struct HoloTodayPlanReplay: Error {
    let existing: HoloTodayPlanRepository.RevisionRow

    nonisolated func receipt() -> HoloTodayPlanReceipt {
        HoloTodayPlanReceipt(
            revisionID: existing.id,
            replayed: true,
            changed: true,
            changedTaskIDs: [],
            createdTaskID: existing.createdTaskID,
            payload: existing.payload
        )
    }
}
