//
//  TaskExperienceSnapshot.swift
//  Holo
//
//  任务记录的不可变纯值快照（方案 §9.1/§9.2）：context 队列内完成唯一副本选择、
//  删除契约过滤与清单归属解析后转纯值；首页分组/计数、新增归属预览、统计聚合
//  全部从同一份快照派生，不跨队列暴露 NSManagedObject。
//

import Foundation
import CoreData

// MARK: - 单任务记录快照

nonisolated struct TaskRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let note: String?
    let importance: TaskImportance
    let urgencyMode: TaskUrgencyMode
    let dueDate: Date?
    let isAllDay: Bool
    let completed: Bool
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
    /// 删除契约：deletedAt 或 deletedFlag 任一标记即删除（方案 §7.3）
    let deleted: Bool
    let listID: UUID?
    /// 当前保存清单名；list == nil 时为 nil（显示「收件箱」）
    let listName: String?
    /// 清单引用存在且未删除（false → 未归属清单桶）
    let listAvailable: Bool
    /// 归档但未删除的清单：保留名称并可标记（方案 §7.3）
    let listIsArchived: Bool
    /// 是否有合法成对的计划时段（非法/半缺按未安排，方案 §6.3）
    let hasValidPlannedRange: Bool
    let priorityRaw: Int16

    @MainActor
    static func make(from task: TodoTask) -> TaskRecordSnapshot {
        let list = task.list
        // 已删除清单不再冒充有效归属：软删清单名不进快照（方案 §7.3）
        let listAvailable = list != nil && list!.deletedAt == nil
        return TaskRecordSnapshot(
            id: task.id,
            title: task.title,
            note: task.desc,
            importance: task.importance,
            urgencyMode: task.urgencyMode,
            dueDate: task.dueDate,
            isAllDay: task.isAllDay,
            completed: task.completed,
            completedAt: task.completedAt,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            archived: task.archived,
            deleted: task.deletedAt != nil || task.deletedFlag,
            listID: list?.id,
            listName: listAvailable ? list?.name : nil,
            listAvailable: listAvailable,
            listIsArchived: listAvailable && (list?.archived ?? false),
            hasValidPlannedRange: {
                guard let start = task.plannedStart, let end = task.plannedEnd else { return false }
                return TodoTask.isValidPlannedRange(start, end)
            }(),
            priorityRaw: task.priority
        )
    }
}

// MARK: - 快照派生规则

extension TaskRecordSnapshot {

    /// 有效截止时刻（全天按当天 23:59:59；与所有新读路径同一规则，方案 §2/§3.2）
    func effectiveDue(calendar: Calendar) -> Date? {
        TodoTaskDatePolicy.effectiveDueDate(dueDate: dueDate, isAllDay: isAllDay, calendar: calendar)
    }

    /// 象限解析（注入 now/calendar）
    func quadrant(now: Date, calendar: Calendar) -> TaskQuadrant {
        TaskQuadrantResolver.quadrant(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDue(calendar: calendar),
            now: now,
            calendar: calendar
        )
    }

    /// 紧急分（2026-10-07）：重要性未判断 → nil（待整理无分）
    func urgencyScore(now: Date, calendar: Calendar) -> Int? {
        TaskQuadrantResolver.urgencyScore(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDue(calendar: calendar),
            now: now,
            calendar: calendar
        )
    }

    /// 未完成且有效截止早于 asOf（逾期事实，不含完成态判断——调用方组合）
    func isOverdue(asOf: Date, calendar: Calendar) -> Bool {
        guard let due = effectiveDue(calendar: calendar) else { return false }
        return due < asOf
    }

    /// 组内默认排序（2026-10-07 紧急分版）：分数降序、无分末尾；
    /// 同分回退原稳定序——有效截止升序、无截止末尾；再创建时间升序、UUID 钉死稳定（方案 §4.3）
    static func defaultOrder(_ lhs: TaskRecordSnapshot, _ rhs: TaskRecordSnapshot, now: Date, calendar: Calendar) -> Bool {
        let lScore = lhs.urgencyScore(now: now, calendar: calendar)
        let rScore = rhs.urgencyScore(now: now, calendar: calendar)
        switch (lScore, rScore) {
        case let (l?, r?) where l != r:
            return l > r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return stableOrder(lhs, rhs, calendar: calendar)
        }
    }

    /// 原稳定序（紧急分同分/无分时的回退）
    private static func stableOrder(_ lhs: TaskRecordSnapshot, _ rhs: TaskRecordSnapshot, calendar: Calendar) -> Bool {
        let lDue = lhs.effectiveDue(calendar: calendar)
        let rDue = rhs.effectiveDue(calendar: calendar)
        switch (lDue, rDue) {
        case let (l?, r?) where l != r:
            return l < r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - 快照集合读取（唯一副本 → 纯值）

nonisolated enum TaskSnapshotReader {

    /// 读取全部任务（含已完成/归档/已删除——统计与搜索需要），完成：
    /// 同 id 唯一副本选择（先选规范行再过滤，方案 §7.3）→ 纯值化。
    /// fetch 失败原样抛出，不返回空数组伪装无数据（方案 §9.4）。
    @MainActor
    static func readAllSnapshots(in context: NSManagedObjectContext) throws -> [TaskRecordSnapshot] {
        let request = TodoTask.fetchRequest()
        let rows = try context.fetch(request)
        let unique = DuplicateRowFilter.deduplicatingCopies(rows)
        return unique.map { TaskRecordSnapshot.make(from: $0) }
    }
}

// MARK: - 首页范围（方案 §4.2）

nonisolated enum TaskExperienceScope: Equatable, Hashable {
    /// 全部未完成（默认）
    case allUncompleted
    /// 今天到期
    case todayDue
    /// 逾期
    case overdue
    /// 收件箱（无清单归属）
    case inbox
    /// 指定清单
    case list(UUID)
    /// 已完成（历史）
    case completed
    /// 归档（历史）
    case archived

    var title: String {
        switch self {
        case .allUncompleted: return String(localized: "全部未完成")
        case .todayDue: return String(localized: "今天到期")
        case .overdue: return String(localized: "逾期")
        case .inbox: return String(localized: "收件箱")
        case .list: return String(localized: "清单")
        case .completed: return String(localized: "已完成")
        case .archived: return String(localized: "归档")
        }
    }

    /// 历史（已完成/归档）范围：连续列表模式，不显示四象限
    var isHistorical: Bool {
        switch self {
        case .completed, .archived: return true
        default: return false
        }
    }

    /// 四象限范围：纳入当前范围的活动未完成任务
    func activeMembers(
        from snapshots: [TaskRecordSnapshot],
        now: Date,
        calendar: Calendar
    ) -> [TaskRecordSnapshot] {
        let active = snapshots.filter { !$0.deleted && !$0.archived && !$0.completed }
        switch self {
        case .allUncompleted:
            return active
        case .todayDue:
            return active.filter { snapshot in
                guard let due = snapshot.effectiveDue(calendar: calendar) else { return false }
                return calendar.isDate(due, inSameDayAs: now)
            }
        case .overdue:
            return active.filter { $0.isOverdue(asOf: now, calendar: calendar) }
        case .inbox:
            return active.filter { $0.listID == nil }
        case .list(let listID):
            return active.filter { $0.listID == listID }
        case .completed, .archived:
            return []
        }
    }

    /// 历史范围成员：已完成按完成时间降序（缺失完成时间沉底）；归档按更新时间降序
    func historicalMembers(
        from snapshots: [TaskRecordSnapshot],
        calendar: Calendar
    ) -> [TaskRecordSnapshot] {
        switch self {
        case .completed:
            let done = snapshots.filter { !$0.deleted && !$0.archived && $0.completed }
            return done.sorted { lhs, rhs in
                switch (lhs.completedAt, rhs.completedAt) {
                case let (l?, r?) where l != r:
                    return l > r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return lhs.updatedAt > rhs.updatedAt
                }
            }
        case .archived:
            let archived = snapshots.filter { !$0.deleted && $0.archived }
            return archived.sorted { $0.updatedAt > $1.updatedAt }
        default:
            return []
        }
    }
}
