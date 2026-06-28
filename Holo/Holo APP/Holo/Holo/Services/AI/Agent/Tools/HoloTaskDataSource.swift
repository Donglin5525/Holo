//
//  HoloTaskDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — 生产任务数据源
//  TodoRepository 是 @MainActor 单例，必须在 MainActor.run 内查询。
//  Repository 层类型（TaskPeriodStats / DailyTaskCount / TodoTask）一律在闭包内转为
//  tool-local 值类型，绝不进入 HoloTaskToolSnapshot（N1 约束）。
//  HoloTaskToolRecord(task:) 依赖 TodoTask，必须留在本文件，不得移入 HoloTaskTool.swift。
//

import Foundation

struct HoloDefaultTaskDataSource: HoloTaskDataSource {

    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot {
        let calendar = Calendar.current
        let end = timeRange?.end ?? Date()
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: end) ?? end)
        return await MainActor.run {
            let repo = TodoRepository.shared
            let todayStats = repo.getTodayTaskStats()
            let period = repo.getCompletionStats(from: start, to: end)
            let trend = repo.getCompletionTrend(from: start, to: end)
            return HoloTaskToolSnapshot(
                todayStats: HoloTodayTaskStats(
                    dueToday: todayStats.dueToday,
                    completedToday: todayStats.completedToday,
                    overdue: todayStats.overdue
                ),
                completionRate: period.completionRate,
                activeBacklogCount: period.activeBacklogCount,
                completionTrend: trend.map { HoloDailyTaskCount(date: $0.date, completedCount: $0.completedCount) },
                overdueTasks: repo.getOverdueTasks().map { HoloTaskToolRecord(task: $0) },
                recentTasks: repo.getUncompletedRecentTasks(limit: 5).map { HoloTaskToolRecord(task: $0) },
                unplannedTasks: repo.getUnplannedOpenTasks(limit: 5).map { HoloTaskToolRecord(task: $0) }
            )
        }
    }
}

extension HoloTaskToolRecord {

    /// 依赖 TodoTask（Core Data），仅限在 MainActor 上下文使用。
    /// 放在本文件而非 HoloTaskTool.swift，避免 standalone tool test 因找不到 Core Data 类型而编译失败。
    @MainActor
    init(task: TodoTask) {
        self.init(
            id: task.id.uuidString,
            title: task.title,
            descExcerpt: task.desc.map { String($0.prefix(80)) },
            priority: Int(task.priority),
            dueDate: task.dueDate,
            plannedDate: task.plannedDate,
            completed: task.completed
        )
    }
}
