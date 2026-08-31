//
//  ScheduleSyncPlanner.swift
//  Holo
//
//  任务↔日历镜像对账决策核心（纯函数，零 EventKit/CoreData 依赖）
//  输入三方快照（任务/事件/映射）→ 输出操作列表；执行层（ScheduleSyncEngine）负责落地。
//  单测锁死全部规则（设计稿二期第 6 节）。
//
//  规则速查：
//  - 任务无映射且带时间段（未删/未归档/未完成）→ 建事件
//  - 任务删除/归档/清时间段 → 删事件+删映射
//  - 任务完成 → 事件保留（不动）
//  - 单边变 → 听变的一边（任务变→改事件；事件变→回流任务，已完成任务不回流）
//  - 双边变（冲突）→ 新者胜（任务 updatedAt vs 事件 lastModifiedDate）
//  - 认领不到事件 → 宽限（默认10分钟）内等待（iCloud 同步延迟）；超时断开映射（用户删事件=断开意图）
//  - 认领最终依据：事件 url 埋的任务 ID；eventIdentifier 仅加速索引
//

import Foundation

// MARK: - 对账快照（值类型）

struct SyncTaskSnapshot: Equatable {
    var taskId: UUID
    var title: String
    var plannedStart: Date?
    var plannedEnd: Date?
    var completed: Bool
    var deleted: Bool
    var archived: Bool
    var updatedAt: Date
}

struct SyncEventSnapshot: Equatable {
    var eventIdentifier: String
    /// 从事件 url（holo-task://<uuid>）认领的任务 ID
    var claimedTaskId: UUID?
    var title: String
    var startDate: Date
    var endDate: Date
    var lastModifiedDate: Date?
}

struct SyncMirrorSnapshot: Equatable {
    var taskId: UUID
    var eventIdentifier: String?
    var state: String
    var lastSyncedStart: Date?
    var lastSyncedEnd: Date?
    var lastSyncedTitle: String?
    var lastSyncedAt: Date
    var lastConfirmedAt: Date
}

// MARK: - 对账产出操作（执行层落地）

enum ScheduleSyncOperation: Equatable {
    /// 建镜像事件（执行层建完回填映射）
    case createEvent(task: SyncTaskSnapshot)
    /// 任务侧变 → 更新事件
    case updateEvent(task: SyncTaskSnapshot, eventIdentifier: String)
    /// 事件侧变 → 回流任务
    case updateTask(taskId: UUID, title: String, plannedStart: Date, plannedEnd: Date)
    /// 任务删除/归档/清时间段 → 删事件+删映射
    case deleteEventAndMirror(eventIdentifier: String, taskId: UUID)
    /// 事件认领超时/用户删事件 → 断开映射（任务保留）
    case disconnectMirror(taskId: UUID)
    /// 事件被改成跨天 → 清任务时间段+删事件+删映射（任务保留）
    /// 任务计划时间段语义是「当天内的时间块」，跨天不属于它；镜像撤除后一轮收敛，不再反复对账
    case detachCrossDayMirror(taskId: UUID, eventIdentifier: String)
}

// MARK: - 决策核心

enum ScheduleSyncPlanner {

    /// 认领宽限：iCloud 事件同步延迟的容忍窗口
    static let claimGraceInterval: TimeInterval = 10 * 60

    static func plan(
        tasks: [SyncTaskSnapshot],
        events: [SyncEventSnapshot],
        mirrors: [SyncMirrorSnapshot],
        now: Date = Date()
    ) -> [ScheduleSyncOperation] {
        var operations: [ScheduleSyncOperation] = []

        let tasksById = Dictionary(tasks.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
        let activeMirrors = mirrors.filter { $0.state == "active" }
        // 断开过的任务不自动重建镜像（用户在日历删事件=断开意图；重建等于删了又冒出来）
        var mirroredTaskIds = Set(mirrors.map(\.taskId))

        // 事件认领索引：eventIdentifier 直查 + 任务 ID 兜底（identifier 漂移后靠 url 认领）
        let eventsByIdentifier = Dictionary(events.map { ($0.eventIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let eventsByClaimedTask = Dictionary(
            events.compactMap { event -> (UUID, SyncEventSnapshot)? in
                guard let taskId = event.claimedTaskId else { return nil }
                return (taskId, event)
            },
            uniquingKeysWith: { first, _ in first }
        )

        func resolveEvent(for mirror: SyncMirrorSnapshot) -> SyncEventSnapshot? {
            if let identifier = mirror.eventIdentifier, let event = eventsByIdentifier[identifier] {
                return event
            }
            return eventsByClaimedTask[mirror.taskId]
        }

        // ---- 第一轮：处理已有映射 ----
        for mirror in activeMirrors {
            guard let event = resolveEvent(for: mirror) else {
                // 认领不到：宽限内等待 iCloud；超时视为用户已删事件 → 断开
                if now.timeIntervalSince(mirror.lastConfirmedAt) > claimGraceInterval {
                    operations.append(.disconnectMirror(taskId: mirror.taskId))
                }
                continue
            }

            guard let task = tasksById[mirror.taskId] else { continue }

            if task.deleted || task.archived {
                operations.append(.deleteEventAndMirror(eventIdentifier: event.eventIdentifier, taskId: mirror.taskId))
                mirroredTaskIds.remove(mirror.taskId)
                continue
            }

            guard let start = task.plannedStart, let end = task.plannedEnd else {
                // 清了时间段：不再属于「带时间段任务」，镜像随之撤销
                operations.append(.deleteEventAndMirror(eventIdentifier: event.eventIdentifier, taskId: mirror.taskId))
                mirroredTaskIds.remove(mirror.taskId)
                continue
            }

            // 三方比对：以 lastSynced 为基线判定哪边变了
            let taskChanged = start != mirror.lastSyncedStart
                || end != mirror.lastSyncedEnd
                || task.title != mirror.lastSyncedTitle
            let eventChanged = event.startDate != mirror.lastSyncedStart
                || event.endDate != mirror.lastSyncedEnd
                || event.title != mirror.lastSyncedTitle

            switch (taskChanged, eventChanged) {
            case (false, false):
                break
            case (true, false):
                operations.append(.updateEvent(task: task, eventIdentifier: event.eventIdentifier))
            case (false, true):
                // 已完成任务不回流（历史记录以日历侧为准）；未完成任务回流
                if !task.completed {
                    if Self.isValidTaskRange(event.startDate, event.endDate) {
                        operations.append(.updateTask(
                            taskId: task.taskId,
                            title: event.title,
                            plannedStart: event.startDate,
                            plannedEnd: event.endDate
                        ))
                    } else {
                        // 事件被改成跨天（或零长）：当天时间块语义失效，撤镜像+清任务时间段
                        operations.append(.detachCrossDayMirror(
                            taskId: task.taskId,
                            eventIdentifier: event.eventIdentifier
                        ))
                    }
                }
            case (true, true):
                // 冲突：新者胜
                let eventModified = event.lastModifiedDate ?? .distantPast
                if task.updatedAt > eventModified {
                    operations.append(.updateEvent(task: task, eventIdentifier: event.eventIdentifier))
                } else {
                    if !task.completed {
                        if Self.isValidTaskRange(event.startDate, event.endDate) {
                            operations.append(.updateTask(
                                taskId: task.taskId,
                                title: event.title,
                                plannedStart: event.startDate,
                                plannedEnd: event.endDate
                            ))
                        } else {
                            operations.append(.detachCrossDayMirror(
                                taskId: task.taskId,
                                eventIdentifier: event.eventIdentifier
                            ))
                        }
                    } else {
                        operations.append(.updateEvent(task: task, eventIdentifier: event.eventIdentifier))
                    }
                }
            }
        }

        // ---- 第二轮：带时间段、无映射的任务 → 建事件 ----
        // 已完成任务跳过：写入开关开启时不回灌历史（否则首次开启会向日历倾倒全部历史完成事件）
        for task in tasks where task.plannedStart != nil && task.plannedEnd != nil {
            guard !mirroredTaskIds.contains(task.taskId),
                  !task.deleted, !task.archived, !task.completed else { continue }
            operations.append(.createEvent(task: task))
        }

        return operations
    }

    /// 任务计划时间段合法性：同一天且开始早于结束（与 TodoTask.isValidPlannedRange 同规则）
    private static func isValidTaskRange(_ start: Date, _ end: Date, calendar: Calendar = .current) -> Bool {
        guard end > start else { return false }
        return calendar.isDate(start, inSameDayAs: end)
    }
}
