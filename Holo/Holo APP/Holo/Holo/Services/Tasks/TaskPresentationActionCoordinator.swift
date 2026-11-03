//
//  TaskPresentationActionCoordinator.swift
//  Holo
//
//  多视图 surface 的动作协调层（多视图方案 §6.3/§8）：象限移动与计划时段的
//  按 UUID 重读、提交、限定字段恢复、3 秒撤回窗口。完成/撤回完成仍归
//  HoloTaskCompletionCoordinator。UI 同一时间只展示一条操作提示；
//  新操作开启时只结束旧提示的可撤回期，不撤销既有业务。
//

import Foundation
import Combine
import os.log

@MainActor
final class TaskPresentationActionCoordinator: ObservableObject {

    static let shared = TaskPresentationActionCoordinator()

    private let logger = Logger(subsystem: "com.holo.app", category: "TaskPresentationAction")

    // MARK: - 可撤回动作

    struct UndoableAction: Identifiable {
        enum Kind {
            case quadrantMove(
                taskID: UUID,
                applied: TaskQuadrantMovePolicy.Patch,
                revert: TaskQuadrantMovePolicy.Patch
            )
            case plannedRange(
                taskID: UUID,
                appliedStart: Date?,
                appliedEnd: Date?,
                revertStart: Date?,
                revertEnd: Date?
            )
        }

        let id = UUID()
        let kind: Kind
        /// 提示文案（调用方按结果组装，如「已移至『留出时间』，时间未改变」）
        let message: String

        var taskID: UUID {
            switch kind {
            case .quadrantMove(let taskID, _, _): return taskID
            case .plannedRange(let taskID, _, _, _, _): return taskID
            }
        }
    }

    /// 当前撤回窗口（UI 顶部 toast 绑定；nil = 无提示）
    @Published private(set) var undoable: UndoableAction?

    /// 无法撤回/操作失败的如实提示（一次一条，随下一动作清除）
    @Published private(set) var failureMessage: String?

    /// 提交中任务（防同一任务重复动作；不锁整页浏览，§6.3-7）
    private var committingTaskIDs: Set<UUID> = []

    /// 撤回窗口时长（与完成协调器同一节奏）
    static let undoWindow: TimeInterval = 3

    /// 在 fireAt 时刻调度一次 fire，返回取消闭包；测试注入假时钟
    var scheduleExpiry: (_ fireAt: Date, _ fire: @escaping () -> Void) -> () -> Void =
        { fireAt, fire in
            let item = DispatchWorkItem(block: fire)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireAt.timeIntervalSinceNow), execute: item)
            return { item.cancel() }
        }

    private var cancelExpiryTimer: (() -> Void)?

    private func cancelTimer() {
        cancelExpiryTimer?()
        cancelExpiryTimer = nil
    }

    private func endPrompt() {
        cancelTimer()
        undoable = nil
    }

    /// 新操作开启：明确结束旧提示（旧分类/计划已保存则只结束可撤回期，不撤销业务，§8）
    func beginNewAction() {
        endPrompt()
        failureMessage = nil
    }

    // MARK: - 象限移动（§6.2/§6.3）

    enum QuadrantMoveOutcome {
        /// 已提交：目标 + 提示文案已进入撤回窗口
        case applied(message: String)
        /// 目标等于当前实时解析格：零写入零提示
        case noOp
        /// 提交前重读对象不可用（已删除 / 已归档 / 已完成）
        case taskUnavailable
        case saveFailed
    }

    @discardableResult
    func commitQuadrantMove(
        taskID: UUID,
        target: TaskQuadrant,
        repository: TodoRepository,
        now: Date = Date(),
        calendar: Calendar = TaskAnalyticsPeriod.makeCalendar()
    ) -> QuadrantMoveOutcome {
        beginNewAction()
        guard let task = repository.findTask(by: taskID) else { return .taskUnavailable }
        guard !task.archived, !task.completed, task.deletedAt == nil else { return .taskUnavailable }

        let importance = task.importance
        let urgencyMode = task.urgencyMode
        let effectiveDue = TodoTaskDatePolicy.effectiveDueDate(
            dueDate: task.dueDate, isAllDay: task.isAllDay, calendar: calendar
        )
        guard let patch = TaskQuadrantMovePolicy.patch(
            target: target,
            importance: importance,
            urgencyMode: urgencyMode,
            effectiveDue: effectiveDue,
            now: now,
            calendar: calendar
        ) else { return .noOp }

        guard !committingTaskIDs.contains(taskID) else { return .noOp }
        committingTaskIDs.insert(taskID)
        defer { committingTaskIDs.remove(taskID) }

        do {
            try repository.updateTaskClassification(
                taskID: taskID,
                importance: patch.importance,
                urgencyMode: patch.urgencyMode
            )
        } catch {
            // 限定字段恢复：只回滚本次写入的两轴与 updatedAt，不动上下文其他编辑
            task.importance = importance
            task.urgencyMode = urgencyMode
            logger.error("象限移动保存失败：\(error.localizedDescription, privacy: .public)")
            return .saveFailed
        }

        let revert = TaskQuadrantMovePolicy.revertPatch(importance: importance, urgencyMode: urgencyMode)
        let message = String(localized: "已移至「\(target.displayTitle)」，时间未改变")
        openUndoWindow(UndoableAction(
            kind: .quadrantMove(taskID: taskID, applied: patch, revert: revert),
            message: message
        ))
        return .applied(message: message)
    }

    // MARK: - 计划时段（§5.4）

    enum PlannedRangeOutcome {
        /// 已提交；revert 为操作前的精确原值（nil 起止 = 原本无计划）
        case applied(message: String)
        /// 同一任务已有提交在途（防重复动作）
        case noOp
        case taskUnavailable
        case saveFailed
    }

    @discardableResult
    func commitPlannedRange(
        taskID: UUID,
        update: TodoRepository.TaskPlannedTimeUpdate,
        repository: TodoRepository
    ) -> PlannedRangeOutcome {
        beginNewAction()
        guard let task = repository.findTask(by: taskID) else { return .taskUnavailable }
        guard !task.archived, !task.completed, task.deletedAt == nil else { return .taskUnavailable }

        guard !committingTaskIDs.contains(taskID) else { return .noOp }
        committingTaskIDs.insert(taskID)
        defer { committingTaskIDs.remove(taskID) }

        do {
            try TaskPlannedTimeCommit.apply(task, update: update) { task, update in
                try repository.updateTask(task, plannedTime: update)
            }
        } catch {
            logger.error("计划时段保存失败：\(error.localizedDescription, privacy: .public)")
            return .saveFailed
        }

        let revertStart = task.plannedStart
        let revertEnd = task.plannedEnd
        let appliedStart: Date?
        let appliedEnd: Date?
        switch update {
        case .set(let start, let end):
            appliedStart = start
            appliedEnd = end
        case .clear:
            appliedStart = nil
            appliedEnd = nil
        }
        let message: String
        switch update {
        case .set:
            message = String(localized: "已更新计划时间，截止未改变")
        case .clear:
            message = String(localized: "已移除计划，截止未改变")
        }
        openUndoWindow(UndoableAction(
            kind: .plannedRange(
                taskID: taskID,
                appliedStart: appliedStart,
                appliedEnd: appliedEnd,
                revertStart: revertStart,
                revertEnd: revertEnd
            ),
            message: message
        ))
        return .applied(message: message)
    }

    // MARK: - 撤回（§6.3-9：按精确原值恢复；字段已被再改则拒绝覆盖）

    func undoCurrent(repository: TodoRepository) {
        guard let action = undoable else { return }
        endPrompt()
        guard let task = repository.findTask(by: action.taskID) else {
            failureMessage = String(localized: "任务已发生变化，请重新查看")
            return
        }
        do {
            switch action.kind {
            case let .quadrantMove(_, applied, revert):
                // 当前值 ≠ 本次提交值 → 已被其他操作/同步再改，拒绝覆盖
                guard task.importance == applied.importance,
                      task.urgencyMode == applied.urgencyMode else {
                    failureMessage = String(localized: "任务已更新，无法撤回这次移动")
                    return
                }
                try repository.updateTaskClassification(
                    taskID: action.taskID,
                    importance: revert.importance,
                    urgencyMode: revert.urgencyMode
                )
            case let .plannedRange(_, appliedStart, appliedEnd, revertStart, revertEnd):
                // 当前计划 ≠ 本次提交值 → 拒绝覆盖后续更改（§8）
                guard task.plannedStart == appliedStart, task.plannedEnd == appliedEnd else {
                    failureMessage = String(localized: "任务已更新，无法撤回这次修改")
                    return
                }
                if let start = revertStart, let end = revertEnd {
                    try repository.updateTask(task, plannedTime: .set(start: start, end: end))
                } else {
                    try repository.updateTask(task, plannedTime: .clear)
                }
            }        } catch {
            // 撤回保存失败如实报错；真实最新快照由调用方 reload 呈现
            logger.error("撤回保存失败：\(error.localizedDescription, privacy: .public)")
            failureMessage = String(localized: "撤回未保存，请重试")
        }
    }

    /// 拖动/计划弹层主动关闭提示（例如用户开始下一次操作前）
    func dismissPrompt() {
        endPrompt()
        failureMessage = nil
    }

    // MARK: - 撤回窗口

    private func openUndoWindow(_ action: UndoableAction) {
        undoable = action
        cancelTimer()
        cancelExpiryTimer = scheduleExpiry(Date().addingTimeInterval(Self.undoWindow)) { [weak self] in
            self?.undoable = nil
        }
    }
}
