//
//  GoalAnalysisContextBuilder.swift
//  Holo
//
//  目标分析上下文构建器
//  计算活跃目标的关联任务/习惯完成率和风险检测
//

import Foundation
import os.log

struct GoalAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "GoalAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> GoalAnalysisContext? {
        let goalRepo = GoalRepository.shared
        let goals = goalRepo.activeGoalsForAI(limit: 20)

        guard !goals.isEmpty else { return nil }

        let calendar = Calendar.current
        let analysisStart = calendar.startOfDay(for: request.start)
        guard let analysisEndExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }
        let analysisRange = analysisStart...analysisEndExclusive

        // 确保习惯仓库已初始化
        let habitRepo = HabitRepository.shared
        if !habitRepo.isReady { habitRepo.setup() }

        var items: [GoalProgressItem] = []
        var atRiskNames: [String] = []

        for goal in goals {
            let item = buildProgressItem(
                goal: goal,
                analysisRange: analysisRange,
                calendar: calendar,
                habitRepo: habitRepo
            )
            items.append(item)

            if item.isOverdue || isAtRisk(item) {
                atRiskNames.append(item.title)
            }
        }

        // 本期完成的目标数
        let completedCount = goalRepo.completedGoalsCount(
            from: analysisStart,
            to: analysisEndExclusive
        )

        // 上期完成数
        var previousCompleted: Int?
        if let compStart = request.comparisonStart, let compEnd = request.comparisonEnd {
            let compStartDay = calendar.startOfDay(for: compStart)
            let compEndExcl = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: compEnd))
            if let compEnd = compEndExcl {
                previousCompleted = goalRepo.completedGoalsCount(from: compStartDay, to: compEnd)
            }
        }

        // 领域分布
        let domainDist = Dictionary(grouping: items, by: \.domain)
            .mapValues { $0.count }

        return GoalAnalysisContext(
            totalActiveGoals: goals.count,
            goals: items,
            completedGoalsInPeriod: completedCount,
            atRiskGoals: atRiskNames,
            domainDistribution: domainDist,
            previousPeriodCompleted: previousCompleted
        )
    }

    // MARK: - 单个目标进度

    @MainActor
    private func buildProgressItem(
        goal: Goal,
        analysisRange: ClosedRange<Date>,
        calendar: Calendar,
        habitRepo: HabitRepository
    ) -> GoalProgressItem {
        let tasks = goal.sortedTasks
        let habits = goal.sortedHabits

        // 任务完成率
        let taskTotal = tasks.count
        let taskCompleted = tasks.filter { $0.completed }.count

        // 习惯完成率（从习惯创建日或分析期开始日中较晚者开始计算）
        let habitTotal = habits.count
        var habitAvgRate: Double?

        if habitTotal > 0 {
            let rates = habits.compactMap { habit -> Double? in
                let habitStart = calendar.startOfDay(for: habit.createdAt)
                let effectiveStart = max(analysisRange.lowerBound, habitStart)
                guard effectiveStart < analysisRange.upperBound else { return nil }
                let effectiveRange = effectiveStart...analysisRange.upperBound
                return habitRepo.evaluatePerformance(for: habit, in: effectiveRange).completionRate
            }
            if !rates.isEmpty {
                habitAvgRate = rates.reduce(0, +) / Double(rates.count)
            }
        }

        // 综合进度：任务 60% + 习惯 40%
        let overallProgress = calculateOverallProgress(
            taskTotal: taskTotal,
            taskCompleted: taskCompleted,
            habitTotal: habitTotal,
            habitAvgRate: habitAvgRate
        )

        // 剩余天数
        let daysRemaining = goal.deadline.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: $0)).day ?? 0
        }

        // 是否逾期
        let isOverdue = goal.deadline.map {
            calendar.startOfDay(for: $0) < calendar.startOfDay(for: Date()) && goal.goalStatus != .completed
        } ?? false

        return GoalProgressItem(
            title: goal.title,
            domain: goal.goalDomain.rawValue,
            status: goal.goalStatus.rawValue,
            deadline: goal.deadline.map { Self.dateFmt.string(from: $0) },
            daysRemaining: daysRemaining,
            linkedTaskTotal: taskTotal,
            linkedTaskCompleted: taskCompleted,
            linkedHabitTotal: habitTotal,
            linkedHabitAverageRate: habitAvgRate,
            overallProgress: overallProgress,
            isOverdue: isOverdue
        )
    }

    /// 综合进度计算：任务 60% + 习惯 40%
    private func calculateOverallProgress(
        taskTotal: Int,
        taskCompleted: Int,
        habitTotal: Int,
        habitAvgRate: Double?
    ) -> Double? {
        let hasTasks = taskTotal > 0
        let hasHabits = habitTotal > 0 && habitAvgRate != nil

        if hasTasks && hasHabits {
            let taskRate = Double(taskCompleted) / Double(taskTotal)
            return taskRate * 0.6 + (habitAvgRate ?? 0) * 0.4
        } else if hasTasks {
            return Double(taskCompleted) / Double(taskTotal)
        } else if hasHabits {
            return habitAvgRate
        }
        return nil
    }

    /// 风险判断：deadline < 7 天且进度 < 50%，或习惯完成率 < 30%
    private func isAtRisk(_ item: GoalProgressItem) -> Bool {
        if let days = item.daysRemaining, days >= 0, days < 7 {
            if let progress = item.overallProgress, progress < 0.5 {
                return true
            }
        }
        if let habitRate = item.linkedHabitAverageRate, habitRate < 0.3 {
            return true
        }
        return false
    }
}
