//
//  HoloWidgetHabitTodoSnapshot.swift
//  Holo
//
//  「今日习惯 / 今日待办」小组件快照的生成与落盘。
//  自 HoloWidgetSnapshotService 搬移而来，供主 App 与小组件扩展进程共用：
//  小组件上的打卡/勾选意图执行后，由本文件在同一进程内重写快照并刷新时间线。
//

import CoreData
import Foundation
import WidgetKit

@MainActor
enum HoloWidgetHabitTodoSnapshotWriter {

    // MARK: - 今日习惯

    static func refreshHabitSnapshot(
        repository: HabitRepository,
        store: HoloWidgetSnapshotStore = HoloWidgetSnapshotStore(),
        date: Date = Date()
    ) {
        let progress = repository.getTodayCheckInProgress()
        let weekPatterns = repository.getWeekCompletionPatterns()

        var longestStreakText = ""
        var longestStreak = 0
        let items = repository.getActiveHabits().prefix(5).map { habit -> HoloWidgetHabitItem in
            let streak = repository.calculateStreakInfo(for: habit)
            if streak.value > longestStreak {
                longestStreak = streak.value
                longestStreakText = streak.displayText
            }
            // 数值型「今日有记录即算完成」与 getTodayCheckInProgress 口径一致
            let isCompleted = habit.isCheckInType
                ? repository.isTodayCompleted(for: habit)
                : repository.getTodayValue(for: habit) != nil
            return HoloWidgetHabitItem(
                id: habit.id,
                name: habit.name,
                icon: habit.icon,
                streakText: streak.value > 0 ? streak.displayText : "",
                isCompletedToday: isCompleted,
                weekPattern: weekPatterns[habit.id] ?? []
            )
        }

        let snapshot = HoloWidgetHabitSnapshot(
            completedToday: progress.completed,
            totalToday: progress.total,
            longestStreakText: longestStreakText,
            habits: Array(items),
            updatedAt: date
        )
        try? store.writeHabit(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.habit.rawValue)
    }

    // MARK: - 今日待办

    static func refreshTodoSnapshot(
        context: NSManagedObjectContext,
        store: HoloWidgetSnapshotStore = HoloWidgetSnapshotStore(),
        date: Date = Date()
    ) {
        // 与任务页「今日」筛选同口径：今天到期 + 逾期未完成。
        // 两个列表存在交集（今天到期且已逾期），按 id 去重，避免组件出现重复行。
        var seen = Set<UUID>()
        var pending = (TodoCompletionCore.getTodayTasks(in: context) + TodoCompletionCore.getOverdueTasks(in: context)).filter {
            seen.insert($0.id).inserted
        }
        pending.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsDue = lhs.dueDate ?? .distantFuture
            let rhsDue = rhs.dueDate ?? .distantFuture
            if lhsDue != rhsDue { return lhsDue < rhsDue }
            return lhs.title < rhs.title
        }

        // 末尾带一条今日已完成的划线样本，桌面能看到「今天推进了什么」
        let completedToday = TodoCompletionCore.fetchActiveTasks(in: context)
            .filter { $0.completed && $0.isDueToday }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }

        var items = pending.prefix(5).map { task in
            HoloWidgetTodoItem(
                id: task.id,
                title: task.title,
                isCompleted: false,
                priority: Int(task.priority),
                isOverdue: task.isOverdue
            )
        }
        if let completedToday {
            items.append(HoloWidgetTodoItem(
                id: completedToday.id,
                title: completedToday.title,
                isCompleted: true,
                priority: Int(completedToday.priority),
                isOverdue: false
            ))
        }

        let progress = TodoCompletionCore.getTodayTaskProgress(in: context)
        let snapshot = HoloWidgetTodoSnapshot(
            completedToday: progress.completed,
            totalToday: progress.total,
            items: items,
            dateText: shortDateText(date),
            updatedAt: date
        )
        try? store.writeTodo(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.todo.rawValue)
    }

    private static let weekdayShortNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// "9.9 周二"（与原 HoloWidgetSnapshotService 口径一致）
    private static func shortDateText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        guard let month = components.month, let day = components.day, let weekday = components.weekday else {
            return ""
        }
        return "\(month).\(day) \(weekdayShortNames[weekday - 1])"
    }
}
