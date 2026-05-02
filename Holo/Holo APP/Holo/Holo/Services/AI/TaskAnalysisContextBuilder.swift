//
//  TaskAnalysisContextBuilder.swift
//  Holo
//
//  任务分析上下文构建器
//  调用 TodoRepository+Stats 的 getCompletionStats 和 getCompletionTrend
//

import Foundation
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

        guard stats.dueInPeriod > 0 else {
            return nil
        }

        let trend = repo.getCompletionTrend(from: startInclusive, to: endExclusive)
        let dailyTrend = trend.prefix(31).map { item in
            DailyCountPoint(date: Self.dateFmt.string(from: item.date), count: item.completedCount)
        }

        // 重要完成的任务标题
        let importantCompleted = repo.activeTasks
            .filter { $0.completed && $0.priority >= 2 }
            .compactMap { $0.title }
            .prefix(5)
            .map { String($0) }

        // 上周期对比
        var previousPeriodCompletedCount: Int?
        if let compStart = request.comparisonStart,
           let compEnd = request.comparisonEnd {
            let compStartDay = calendar.startOfDay(for: compStart)
            let compEndDay = calendar.startOfDay(for: compEnd)
            let compStats = repo.getCompletionStats(from: compStartDay, to: compEndDay)
            previousPeriodCompletedCount = compStats.completedInPeriod
        }

        return TaskAnalysisContext(
            totalCount: stats.dueInPeriod,
            completedCount: stats.completedInPeriod,
            overdueCount: stats.overdueInPeriod,
            completionRate: stats.completionRate,
            highPriorityCompletionRate: stats.highPriorityCompletionRate,
            importantCompletedTasks: Array(importantCompleted),
            dailyCompletionTrend: dailyTrend,
            previousPeriodCompletedCount: previousPeriodCompletedCount
        )
    }
}
