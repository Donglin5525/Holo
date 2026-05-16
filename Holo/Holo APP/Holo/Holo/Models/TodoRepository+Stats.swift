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

    /// 获取总任务数统计
    func getTaskStatistics() -> (total: Int, completed: Int, overdue: Int) {
        let total = activeTasks.count
        let completed = activeTasks.filter { $0.completed }.count
        let overdue = getOverdueTasks().count
        return (total, completed, overdue)
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
