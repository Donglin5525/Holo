//
//  TaskAnalysisContextBuilder.swift
//  Holo
//
//  任务分析上下文构建器
//  调用 TodoRepository+Stats 的 getCompletionStats 和 getCompletionTrend
//

import Foundation
import CoreData
import os.log

struct TaskAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "TaskAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> TaskAnalysisContext? {
        let repo = TodoRepository.shared
        let calendar = Calendar.current
        let startInclusive = calendar.startOfDay(for: request.start)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }

        let stats = repo.getCompletionStats(from: startInclusive, to: endExclusive)

        guard stats.dueInPeriod > 0 || stats.completedInPeriod > 0 || stats.createdInPeriod > 0 || stats.activeBacklogCount > 0 else {
            return nil
        }

        let trend = repo.getCompletionTrend(from: startInclusive, to: endExclusive)
        let dailyTrend = trend.prefix(31).map { item in
            DailyCountPoint(date: Self.dateFmt.string(from: item.date), count: item.completedCount)
        }

        // 重要完成的任务标题
        let importantCompleted = fetchImportantCompletedTasks(from: startInclusive, to: endExclusive)

        // 上周期对比
        var previousPeriodCompletedCount: Int?
        if let compStart = request.comparisonStart,
           let compEnd = request.comparisonEnd {
            let compStartDay = calendar.startOfDay(for: compStart)
            let compEndDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: compEnd)) ?? calendar.startOfDay(for: compEnd)
            let compStats = repo.getCompletionStats(from: compStartDay, to: compEndDay)
            previousPeriodCompletedCount = compStats.completedInPeriod
        }

        return TaskAnalysisContext(
            totalCount: stats.dueInPeriod,
            completedCount: stats.completedInPeriod,
            overdueCount: stats.overdueInPeriod,
            completionRate: stats.completionRate,
            highPriorityCompletionRate: stats.highPriorityCompletionRate,
            importantCompletedTasks: importantCompleted,
            dailyCompletionTrend: dailyTrend,
            previousPeriodCompletedCount: previousPeriodCompletedCount,
            dueInPeriod: stats.dueInPeriod,
            createdInPeriod: stats.createdInPeriod,
            completedInPeriod: stats.completedInPeriod,
            newOverdueInPeriod: stats.overdueInPeriod,
            carriedOverBacklogCount: stats.carriedOverBacklogCount,
            activeBacklogCount: stats.activeBacklogCount,
            periodCompletionScopeNote: "完成率仅以本周期到期任务为分母；历史积压单独放在 carriedOverBacklogCount / activeBacklogCount，不代表本周期失败。"
        )
    }

    @MainActor
    private func fetchImportantCompletedTasks(from start: Date, to end: Date) -> [String] {
        let context = CoreDataStack.shared.viewContext
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(
            format: "completed == YES AND priority >= 2 AND completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
            start as CVarArg,
            end as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
        request.fetchLimit = 5
        return ((try? context.fetch(request)) ?? [])
            .compactMap(\.title)
            .map { String($0) }
    }
}
