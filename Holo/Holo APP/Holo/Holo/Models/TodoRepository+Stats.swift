//
//  TodoRepository+Stats.swift
//  Holo
//
//  待办统计相关方法
//

import Foundation
import CoreData
import os

extension TodoRepository {

    // MARK: - Statistics

    /// 获取今日任务完成进度
    func getTodayTaskProgress() -> (completed: Int, total: Int) {
        let todayTasks = getTodayTasks()
        guard !todayTasks.isEmpty else { return (0, 0) }
        let completed = todayTasks.filter { $0.completed }.count
        return (completed, todayTasks.count)
    }

    /// 获取按优先级分组的任务统计
    func getTasksGroupedByPriority() -> [TaskPriority: Int] {
        var result: [TaskPriority: Int] = [:]
        for priority in TaskPriority.allCases {
            result[priority] = getTasks(priority: priority).count
        }
        return result
    }

    /// 获取总任务数统计（全量活跃，不含时间过滤）
    func getTaskStatistics() -> (total: Int, completed: Int, overdue: Int) {
        let total = activeTasks.count
        let completed = activeTasks.filter { $0.completed }.count
        let overdue = getOverdueTasks().count
        return (total, completed, overdue)
    }

    /// 今日任务统计（用于 AI 上下文）
    /// - dueToday: 今日到期任务数（含已完成和未完成）
    /// - completedToday: 今日完成任务数（不限截止日期）
    /// - overdue: 逾期未完成任务数
    func getTodayTaskStats() -> (dueToday: Int, completedToday: Int, overdue: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return (0, 0, 0)
        }

        let base = "deletedFlag == NO AND archived == NO"

        // 今日到期（不管是否已完成）
        let dueToday = countTasks(
            predicate: "\(base) AND dueDate >= %@ AND dueDate < %@",
            today as NSDate, tomorrow as NSDate
        )

        // 今日完成（completedAt 在今天，不限 dueDate）
        let completedToday = countTasks(
            predicate: "\(base) AND completed == YES AND completedAt >= %@ AND completedAt < %@",
            today as NSDate, tomorrow as NSDate
        )

        // 逾期（截止日已过且未完成）
        let overdue = countTasks(
            predicate: "\(base) AND completed == NO AND dueDate < %@",
            today as NSDate
        )

        return (dueToday, completedToday, overdue)
    }

    /// 按日分组的完成趋势
    func getCompletionTrend(from start: Date, to end: Date) -> [DailyTaskCount] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completedAt >= %@ AND completedAt <= %@ AND deletedFlag == NO AND archived == NO",
            start as NSDate,
            end as NSDate
        )

        guard let tasks = try? context.fetch(request) else {
            Logger(subsystem: "com.holo.app", category: "TodoRepository")
                .error("获取完成趋势失败")
            return []
        }

        let calendar = Calendar.current
        var grouped: [Date: Int] = [:]
        for task in tasks {
            guard let completedAt = task.completedAt else { continue }
            let day = calendar.startOfDay(for: completedAt)
            grouped[day, default: 0] += 1
        }

        return grouped.map { DailyTaskCount(date: $0.key, completedCount: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// 获取指定时间范围内已完成的任务实体（半开区间 [start, end)，按 completedAt）
    ///
    /// 用于日历聚合：与 getCompletionTrend 不同，返回 [TodoTask] 实体而非每日计数；
    /// 区间用半开 [start, end) 与日历其他模块统一（getCompletionTrend 用闭区间，日历不复用）。
    func getTasks(completedFrom start: Date, completedTo end: Date) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// 通用：按指定日期字段取任务实体（半开区间，支持 completedAt/dueDate/plannedDate）
    ///
    /// 用于日历 P2 待办维度切换：同一个 fetch 适配完成/到期/计划三种时间语义。
    /// 用 %K 动态字段名；字段为 nil 的任务自动不匹配（如无 dueDate 的任务在 .due 维度被跳过）。
    func getTasks(field: String, from start: Date, to end: Date) -> [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "%K >= %@ AND %K < %@ AND deletedFlag == NO AND archived == NO",
            field, start as NSDate, field, end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: field, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// 指定时间范围内的完成统计
    func getCompletionStats(from start: Date, to end: Date) -> TaskPeriodStats {
        // end 约定为开区间，避免把下一天 00:00 的任务误算进本周期。
        let basePredicate = "deletedFlag == NO AND archived == NO"
        let completedInPeriod = countTasks(
            predicate: "\(basePredicate) AND completed == YES AND completedAt >= %@ AND completedAt < %@",
            start as NSDate,
            end as NSDate
        )
        let dueInPeriod = countTasks(
            predicate: "\(basePredicate) AND dueDate >= %@ AND dueDate < %@",
            start as NSDate,
            end as NSDate
        )
        let overdueInPeriod = countTasks(
            predicate: "\(basePredicate) AND completed == NO AND dueDate >= %@ AND dueDate < %@",
            start as NSDate,
            end as NSDate
        )
        let createdInPeriod = countTasks(
            predicate: "\(basePredicate) AND createdAt >= %@ AND createdAt < %@",
            start as NSDate,
            end as NSDate
        )
        let carriedOverBacklogCount = countTasks(
            predicate: "\(basePredicate) AND completed == NO AND dueDate < %@",
            start as NSDate
        )
        let activeBacklogCount = countTasks(
            predicate: "\(basePredicate) AND completed == NO"
        )

        let denominator = max(dueInPeriod, 1)
        let completionRate = Double(completedInPeriod) / Double(denominator)

        // 高优先级完成率
        let highPriorityDue = countTasks(
            predicate: "\(basePredicate) AND priority >= 2 AND dueDate >= %@ AND dueDate < %@",
            start as NSDate,
            end as NSDate
        )
        let highPriorityCompleted = countTasks(
            predicate: "\(basePredicate) AND priority >= 2 AND completed == YES AND completedAt >= %@ AND completedAt < %@",
            start as NSDate,
            end as NSDate
        )
        let highPriorityCompletionRate: Double? = highPriorityDue == 0
            ? nil
            : Double(highPriorityCompleted) / Double(highPriorityDue)

        return TaskPeriodStats(
            completedInPeriod: completedInPeriod,
            dueInPeriod: dueInPeriod,
            overdueInPeriod: overdueInPeriod,
            completionRate: completionRate,
            highPriorityCompletionRate: highPriorityCompletionRate,
            createdInPeriod: createdInPeriod,
            carriedOverBacklogCount: carriedOverBacklogCount,
            activeBacklogCount: activeBacklogCount
        )
    }

    private func countTasks(predicate format: String, _ args: CVarArg...) -> Int {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: format, argumentArray: args)
        do {
            return try context.count(for: request)
        } catch {
            Logger(subsystem: "com.holo.app", category: "TodoRepository")
                .error("获取任务统计失败: \(error.localizedDescription)")
            return 0
        }
    }

    /// 获取未来 N 天内即将到期的第一个未完成任务（按截止时间升序）
    func getNextUpcomingTask(withinDays days: Int = 3) -> TodoTask? {
        let now = Date()
        guard let futureDate = Calendar.current.date(byAdding: .day, value: days, to: now) else {
            return nil
        }

        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND archived == NO AND completed == NO AND dueDate >= %@ AND dueDate < %@",
            now as NSDate,
            futureDate as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "dueDate", ascending: true)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 获取未完成任务总数
    func getIncompleteTaskCount() -> Int {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND archived == NO AND completed == NO"
        )
        return (try? context.count(for: request)) ?? 0
    }
}
