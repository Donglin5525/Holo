//
//  TodoRepository+Postpone.swift
//  Holo
//
//  任务延期落库：改截止时间 + 延期计数 + 提醒通知跟随重排。
//  撤回通过快照整体还原（含计数），列表/详情/通知按钮三个入口共用。
//

import Foundation
import CoreData
import os.log

/// 延期撤回快照：还原 dueDate / isAllDay / postponedCount 三元组
struct TaskPostponeSnapshot {
    let taskId: UUID
    let dueDate: Date
    let isAllDay: Bool
    let postponedCount: Int16
}

extension TodoRepository {

    private static let postponeLogger = Logger(
        subsystem: "com.holo.app", category: "TodoRepository.Postpone"
    )

    /// 延期单个任务到面板选项的落点；返回撤回快照
    @discardableResult
    func postpone(task: TodoTask, to option: TaskPostponeOption) throws -> TaskPostponeSnapshot {
        guard let targetDate = option.targetDate else {
            throw TodoPostponeError.missingTargetDate
        }
        return try postpone(task: task, toDate: targetDate, isAllDay: option.isAllDay)
    }

    /// 延期落库。通知按钮「延期15分钟」（DueDate + 15min）也走这里，
    /// 保证无论哪个入口延期，计数与提醒重排行为一致。
    @discardableResult
    func postpone(
        task: TodoTask,
        toDate newDate: Date,
        isAllDay newIsAllDay: Bool
    ) throws -> TaskPostponeSnapshot {
        let snapshot = TaskPostponeSnapshot(
            taskId: task.id,
            dueDate: task.dueDate ?? newDate,
            isAllDay: task.isAllDay,
            postponedCount: task.postponedCount
        )

        task.dueDate = newDate
        task.isAllDay = newIsAllDay
        task.postponedCount += 1
        task.updatedAt = Date()

        try context.save()
        loadActiveTasks()
        notifyDataChange()

        // 提醒是「截止前 N 分钟」的相对偏移，跟随新截止时间整体重排
        if !task.completed, task.deletedAt == nil, !task.archived, task.hasReminders {
            Task {
                await TodoNotificationService.shared.cancelReminders(for: task)
                try? await TodoNotificationService.shared.scheduleReminder(
                    for: task, reminders: task.remindersArray
                )
            }
        }

        return snapshot
    }

    /// 过期任务批量推到今天（跳过重复任务；与单任务「今天」档共用落点规则）
    @discardableResult
    func postponeOverdueToToday(now: Date = Date()) throws -> [TaskPostponeSnapshot] {
        let overdue = getOverdueTasks().filter { $0.repeatRule == nil }
        var snapshots: [TaskPostponeSnapshot] = []
        for task in overdue {
            let (target, _) = TaskPostponePolicy.overdueTodayTarget(
                dueDate: task.dueDate ?? now,
                isAllDay: task.isAllDay,
                now: now
            )
            snapshots.append(
                try postpone(task: task, toDate: target, isAllDay: task.isAllDay)
            )
        }
        return snapshots
    }

    /// 撤回延期：按快照还原（含延期计数），并重排提醒
    func restorePostponed(_ snapshots: [TaskPostponeSnapshot]) {
        var restoredTasks: [TodoTask] = []
        for snapshot in snapshots {
            guard let task = findTask(by: snapshot.taskId) else { continue }
            task.dueDate = snapshot.dueDate
            task.isAllDay = snapshot.isAllDay
            task.postponedCount = snapshot.postponedCount
            task.updatedAt = Date()
            restoredTasks.append(task)
        }
        guard !restoredTasks.isEmpty else { return }

        do {
            try context.save()
        } catch {
            Self.postponeLogger.error("撤回延期失败：\(error.localizedDescription)")
        }
        loadActiveTasks()
        notifyDataChange()

        for task in restoredTasks {
            rescheduleRemindersIfNeeded(for: task)
        }
    }
}

// MARK: - Error

enum TodoPostponeError: LocalizedError {
    case missingTargetDate

    var errorDescription: String? {
        switch self {
        case .missingTargetDate:
            return "延期目标时间缺失"
        }
    }
}
