//
//  GoalRiskEvaluator.swift
//  Holo
//
//  目标风险判定：截止临近 / 长期停滞
//  风险通知（GoalNotificationService）与目标分析上下文共用同一套规则
//

import Foundation

/// 风险类型（三期量化目标在此扩展新分支）
enum GoalRiskKind: Equatable {
    /// 截止临近且进度落后
    case deadline(daysRemaining: Int, progress: Double)
    /// 长期无关联行动
    case stagnant

    /// 通知排程用的稳定标识（identifier / 去重 key 共用）
    var identifierKey: String {
        switch self {
        case .deadline: return "deadline"
        case .stagnant: return "stagnant"
        }
    }
}

/// 单个目标的风险评估结果
struct GoalRiskAssessment {
    let kind: GoalRiskKind
    /// 面向用户的风险描述
    let summary: String
}

enum GoalRiskEvaluator {

    /// 截止风险规则：deadline ≤7 天且进度 <50%
    static func isDeadlineRisk(daysRemaining: Int?, progress: Double?) -> Bool {
        guard let days = daysRemaining, days >= 0, days < 7 else { return false }
        guard let progress else { return false }
        return progress < 0.5
    }

    /// 评估目标当前的风险（截止优先于停滞）；nil 表示无风险。
    /// 量化目标走预测口径：预测无法在截止前达成 = 截止风险；停滞规则不适用
    /// （量化目标没有「关联行动」概念，进度不动时预测结论会自然变差）
    @MainActor
    static func assess(goal: Goal, now: Date = Date()) -> GoalRiskAssessment? {
        if goal.isQuantitative {
            return assessQuantitative(goal: goal, now: now)
        }

        let calendar = Calendar.current
        let tasks = goal.sortedTasks
        let habits = goal.sortedHabits

        let progress = GoalProgressEvaluator.overallProgress(
            taskTotal: tasks.count,
            taskCompleted: tasks.filter { $0.completed }.count,
            habitTotal: habits.count,
            habitAvgRate: GoalProgressEvaluator.averageHabitCompletionRate(habits: habits)
        )

        if let deadline = goal.deadline {
            let daysRemaining = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: deadline)
            ).day ?? 0
            if isDeadlineRisk(daysRemaining: daysRemaining, progress: progress) {
                let percent = Int(((progress ?? 0) * 100).rounded())
                let dayText = daysRemaining == 0 ? "今天" : "还有 \(daysRemaining) 天"
                let incomplete = tasks.filter { !$0.completed }.count
                let summary: String
                if incomplete > 0 {
                    summary = "“\(goal.title)”还剩 \(incomplete) 个关联任务没动，\(dayText)截止（进度 \(percent)%）。今天清一件就追得回来"
                } else {
                    summary = "“\(goal.title)”\(dayText)截止，进度 \(percent)%。从一件 10 分钟的小事推进？"
                }
                return GoalRiskAssessment(
                    kind: .deadline(daysRemaining: daysRemaining, progress: progress ?? 0),
                    summary: summary
                )
            }
        }

        if isStagnant(goal: goal, tasks: tasks, habits: habits, now: now) {
            return GoalRiskAssessment(
                kind: .stagnant,
                summary: "“\(goal.title)”停了两周，任务和打卡都没动静。从一件 10 分钟的小事重启？"
            )
        }
        return nil
    }

    /// 量化目标截止风险：GoalMetricEvaluator 预测「无法按期达成」才报，
    /// 低速段（进度 <10% 无预测）不报，避免刚起步就提醒
    @MainActor
    private static func assessQuantitative(goal: Goal, now: Date) -> GoalRiskAssessment? {
        guard let deadline = goal.deadline,
              let metric = GoalMetricEvaluator.evaluate(goal: goal),
              metric.forecast?.meetsDeadline == false else { return nil }

        let calendar = Calendar.current
        let daysRemaining = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: deadline)
        ).day ?? 0
        // 已过截止的目标不再提醒（否则每次重排都会发一条「难以达成」）
        guard daysRemaining >= 0 else { return nil }

        let unit = goal.metricUnitText.isEmpty ? "" : " \(goal.metricUnitText)"
        let remaining = abs((goal.metricTargetValueDouble ?? 0) - metric.currentValue)
        let dayText = daysRemaining <= 0 ? "已到截止" : "还有 \(daysRemaining) 天"
        return GoalRiskAssessment(
            kind: .deadline(daysRemaining: daysRemaining, progress: metric.progress),
            summary: "“\(goal.title)”按当前速度赶不上了：还差 \(GoalMetricEvaluator.formatValue(remaining))\(unit)、\(dayText)。把节奏提上来还来得及"
        )
    }

    /// 停滞规则：目标建立满 14 天，且无已完成关联任务、近 14 天无习惯打卡/记录
    @MainActor
    private static func isStagnant(goal: Goal, tasks: [TodoTask], habits: [Habit], now: Date) -> Bool {
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: now)),
              goal.createdAt <= windowStart else { return false }
        if tasks.contains(where: \.completed) { return false }
        return !habits.contains { habit in
            habit.recordsArray.contains { $0.date >= windowStart }
        }
    }
}
