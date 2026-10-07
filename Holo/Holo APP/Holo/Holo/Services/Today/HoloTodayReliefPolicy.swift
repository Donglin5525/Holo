//
//  HoloTodayReliefPolicy.swift
//  Holo
//
//  「今天减负」纯值规则层（2026-10-03 实施方案 §7.2/§7.4）
//
//  - 无 Core Data / SwiftUI / 系统时钟依赖：全部事实由调用方以纯值传入；
//  - payload 结构合法性（去重/互斥/上限/inheritBase 形态）；
//  - 引用有效性（任务存在/可见/未完成、步骤归属/内容指纹/未完成）；
//  - 期限风险（全天口径与 TodoTaskDatePolicy 一致）与确认指纹；
//  - 日目标状态派生（§7.4 表格的唯一实现，Today/详情/Widget 共用）。
//

import Foundation
import CryptoKit

nonisolated enum HoloTodayReliefPolicy {

    // MARK: - 事实快照（纯值，供校验与派生）

    nonisolated struct TaskFact: Equatable, Sendable {
        let id: UUID
        let title: String
        let dueDate: Date?
        let isAllDay: Bool
        let completed: Bool
        /// deletedAt != nil / archived / 父链不可见 → false。
        let visible: Bool
    }

    nonisolated struct StepFact: Equatable, Sendable {
        let id: UUID
        let taskID: UUID
        let actionText: String?
        let doneWhen: String?
        let stateRaw: String
        let originRevisionID: UUID
    }

    /// 一次校验所需的全部事实（由 Repository/Builder 批量取齐后传入）。
    nonisolated struct Facts: Equatable, Sendable {
        let tasks: [UUID: TaskFact]
        let steps: [UUID: StepFact]

        init(tasks: [UUID: TaskFact] = [:], steps: [UUID: StepFact] = [:]) {
            self.tasks = tasks
            self.steps = steps
        }
    }

    // MARK: - 期限风险（§4.3：全天截止按日末，不用 00:00）

    /// 实际期限指纹（期限被编辑 → 原确认失效）；无截止返回 nil（无需确认）。
    nonisolated static func deadlineFingerprint(dueDate: Date?, isAllDay: Bool) -> String? {
        guard let dueDate else { return nil }
        let effectiveSeconds: Int
        if isAllDay {
            // 全天任务只按日期对齐（同日不同入库时刻指纹不变），口径与 TodoTaskDatePolicy 日末一致
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let comps = calendar.dateComponents([.year, .month, .day], from: dueDate)
            effectiveSeconds = comps.year! * 10_000 + comps.month! * 100 + comps.day!
        } else {
            effectiveSeconds = Int(dueDate.timeIntervalSince1970)
        }
        let basis = "due=\(effectiveSeconds)|allDay=\(isAllDay ? 1 : 0)"
        let hash = SHA256.hash(data: Data(basis.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 是否为「今日到期或已逾期」：放下时需要行内风险确认。
    /// 口径：实际截止时刻（全天=当日末）早于本 scope 结束。
    nonisolated static func needsDeadlineAcknowledgement(dueDate: Date?, isAllDay: Bool, scope: HoloTodayDayScope) -> Bool {
        guard let dueDate else { return false }
        let effective: Date
        if isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: scope.timeZoneIdentifier) ?? .current
            effective = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: dueDate)
                ?? scope.dayEnd
        } else {
            effective = dueDate
        }
        return effective < scope.dayEnd
    }

    /// 确认是否仍然有效：任务期限指纹与当日范围内记录的指纹一致。
    nonisolated static func isAcknowledgementValid(
        taskID: UUID,
        dueDate: Date?,
        isAllDay: Bool,
        payload: HoloTodayPlanPayload
    ) -> Bool {
        guard let current = deadlineFingerprint(dueDate: dueDate, isAllDay: isAllDay) else {
            // 无截止 → 无需确认（视为有效）
            return true
        }
        return payload.deadlineAcknowledgements.contains {
            $0.taskID == taskID && $0.deadlineFingerprint == current
        }
    }

    // MARK: - payload 结构合法性

    nonisolated enum PayloadStructureError: Error, Equatable {
        case tooManyEntries(Int)
        case duplicateEntries
        case entriesDeferredOverlap(UUID)
        case duplicateDeferred
        case duplicateMustIDs
        case inheritBaseNotEmpty
        case unsupportedSchemaVersion(Int)
    }

    /// 结构归一化检查：去重要求、互斥、上限、inheritBase 形态（§7.2）。
    nonisolated static func validateStructure(_ payload: HoloTodayPlanPayload) throws {
        guard payload.schemaVersion == HoloTodayPlanPayload.schemaVersion else {
            throw PayloadStructureError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        guard payload.entries.count <= HoloTodayPlanPayload.maxEntries else {
            throw PayloadStructureError.tooManyEntries(payload.entries.count)
        }
        guard Set(payload.entries.map(\.taskID)).count == payload.entries.count else {
            throw PayloadStructureError.duplicateEntries
        }
        guard Set(payload.deferredTaskIDs).count == payload.deferredTaskIDs.count else {
            throw PayloadStructureError.duplicateDeferred
        }
        guard Set(payload.confirmedMustTaskIDs).count == payload.confirmedMustTaskIDs.count else {
            throw PayloadStructureError.duplicateMustIDs
        }
        if let overlap = Set(payload.entries.map(\.taskID))
            .intersection(payload.deferredTaskIDs).first {
            throw PayloadStructureError.entriesDeferredOverlap(overlap)
        }
        if payload.selectionMode == .inheritBase,
           !(payload.entries.isEmpty && payload.deferredTaskIDs.isEmpty && payload.confirmedMustTaskIDs.isEmpty) {
            throw PayloadStructureError.inheritBaseNotEmpty
        }
    }

    // MARK: - 引用有效性（写入前校验，§8.1 步骤 3/4）

    nonisolated enum ValidationError: Error, Equatable {
        case taskMissing(UUID)
        case taskInvisible(UUID)
        case taskCompleted(UUID)
        case stepMissing(UUID)
        case stepNotInTask(stepID: UUID, taskID: UUID)
        case stepContentChanged(stepID: UUID)
        case stepAlreadyDone(stepID: UUID)
        case mustNotSelected(UUID)
        case deferredTaskMissing(UUID)
        case deadlineAcknowledgementRequired(UUID)
    }

    /// 校验显式 payload 的全部引用：任务存在/可见/未完成、步骤归属/指纹/未完成、
    /// 放下今日到期任务的确认齐备。新创建任务（尚不在 facts 中）由调用方先补进 facts。
    nonisolated static func validateReferences(
        _ payload: HoloTodayPlanPayload,
        facts: Facts,
        scope: HoloTodayDayScope
    ) throws {
        for entry in payload.entries {
            guard let task = facts.tasks[entry.taskID] else {
                throw ValidationError.taskMissing(entry.taskID)
            }
            guard task.visible else { throw ValidationError.taskInvisible(entry.taskID) }
            guard !task.completed else { throw ValidationError.taskCompleted(entry.taskID) }
            if case .existingStep(let stepID, _, let contentFingerprint) = entry.goal {
                guard let step = facts.steps[stepID] else {
                    throw ValidationError.stepMissing(stepID)
                }
                guard step.taskID == entry.taskID else {
                    throw ValidationError.stepNotInTask(stepID: stepID, taskID: entry.taskID)
                }
                guard stepFingerprint(step) == contentFingerprint else {
                    throw ValidationError.stepContentChanged(stepID: stepID)
                }
                guard step.stateRaw != HoloTaskExecutionStepState.done.rawValue else {
                    throw ValidationError.stepAlreadyDone(stepID: stepID)
                }
            }
        }
        for taskID in payload.deferredTaskIDs {
            guard let task = facts.tasks[taskID] else {
                throw ValidationError.deferredTaskMissing(taskID)
            }
            guard task.visible else { throw ValidationError.taskInvisible(taskID) }
            if needsDeadlineAcknowledgement(dueDate: task.dueDate, isAllDay: task.isAllDay, scope: scope),
               !isAcknowledgementValid(taskID: taskID, dueDate: task.dueDate, isAllDay: task.isAllDay, payload: payload) {
                throw ValidationError.deadlineAcknowledgementRequired(taskID)
            }
        }
        for taskID in payload.confirmedMustTaskIDs {
            guard facts.tasks[taskID] != nil else { throw ValidationError.taskMissing(taskID) }
        }
    }

    /// 步骤内容指纹：actionText + doneWhen（originRevisionID 变化不失效，§7.4）。
    nonisolated static func stepFingerprint(_ step: StepFact) -> String {
        let basis = "action=\(step.actionText ?? "")|doneWhen=\(step.doneWhen ?? "")"
        let hash = SHA256.hash(data: Data(basis.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 日目标状态派生（§7.4 表格）

    nonisolated enum GoalState: Equatable, Sendable {
        /// 仍可推进（taskResult 未完成 / 指定步骤未完成）。
        case pending
        /// 今日目标已达到（根完成或指定步骤完成），根任务完成事实按原统计。
        case goalReached
        /// 步骤被替换/删除、契约失效：需打开原任务复核，不能标完成。
        case needsRecheck(reason: String)
        /// 任务删除/归档/父链不可见：不进入活跃列表、焦点、数量。
        case excluded(reason: String)
    }

    nonisolated static func goalState(entry: HoloTodaySelectionEntry, facts: Facts) -> GoalState {
        guard let task = facts.tasks[entry.taskID] else {
            return .excluded(reason: "taskMissing")
        }
        guard task.visible else {
            return .excluded(reason: "taskInvisible")
        }
        switch entry.goal {
        case .taskResult:
            return task.completed ? .goalReached : .pending
        case .existingStep(let stepID, _, let contentFingerprint):
            // 根任务被直接完成：目标达到，未做步骤不伪造完成（§7.4）
            if task.completed { return .goalReached }
            guard let step = facts.steps[stepID] else {
                return .needsRecheck(reason: "stepMissing")
            }
            guard step.taskID == entry.taskID else {
                return .needsRecheck(reason: "stepNotInTask")
            }
            guard stepFingerprint(step) == contentFingerprint else {
                return .needsRecheck(reason: "stepContentChanged")
            }
            if step.stateRaw == HoloTaskExecutionStepState.done.rawValue {
                // 步骤完成、根未完成：今天推进到这里，不自动选下一步
                return .goalReached
            }
            return .pending
        }
    }

    /// 步骤被用户撤回（done → pending）：原今日目标重新待推进。
    /// 撤回后 stateVersion 变化但 ID/内容不变 → 同一 GoalState(pending) 自然成立，无需单独状态。
}
