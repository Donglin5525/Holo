//
//  GoalProgressEvaluator.swift
//  Holo
//
//  目标进展评估：原始指标摘要和粗粒度状态
//

import Foundation

enum GoalProgressState: String, Codable {
    case starting
    case progressing
    case stalled
    case nearComplete
    case paused
    case completed

    var displayName: String {
        switch self {
        case .starting: return "起步中"
        case .progressing: return "稳定推进"
        case .stalled: return "有些停滞"
        case .nearComplete: return "接近完成"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        }
    }
}

struct GoalProgressSummary: Equatable {
    let state: GoalProgressState
    let taskSummary: String
    let habitSummary: String
}

@MainActor
enum GoalProgressEvaluator {
    static func evaluate(goal: Goal) -> GoalProgressSummary {
        if goal.goalStatus == .paused {
            return GoalProgressSummary(state: .paused, taskSummary: taskSummary(goal), habitSummary: habitSummary(goal))
        }
        if goal.goalStatus == .completed {
            return GoalProgressSummary(state: .completed, taskSummary: taskSummary(goal), habitSummary: habitSummary(goal))
        }

        let tasks = goal.sortedTasks
        let completedTasks = tasks.filter { $0.completed }.count
        let habits = goal.sortedHabits
        let habitRate = averageHabitCompletionRate(habits: habits)

        let state: GoalProgressState
        if tasks.isEmpty && habits.isEmpty {
            state = .starting
        } else if !tasks.isEmpty && completedTasks >= max(1, Int(Double(tasks.count) * 0.8)) && (habitRate ?? 100) >= 60 {
            state = .nearComplete
        } else if (!tasks.isEmpty && completedTasks > 0) || (habitRate ?? 0) >= 60 {
            state = .progressing
        } else {
            state = .stalled
        }

        return GoalProgressSummary(state: state, taskSummary: taskSummary(goal), habitSummary: habitSummary(goal))
    }

    static func taskSummary(_ goal: Goal) -> String {
        let tasks = goal.sortedTasks
        guard !tasks.isEmpty else { return "尚未关联任务" }
        let completed = tasks.filter { $0.completed }.count
        return "任务 \(completed)/\(tasks.count)"
    }

    static func habitSummary(_ goal: Goal) -> String {
        let habits = goal.sortedHabits
        guard !habits.isEmpty else { return "尚未关联习惯" }
        if let rate = averageHabitCompletionRate(habits: habits) {
            return "近 14 天 \(Int(rate))%"
        }
        return "习惯暂无记录"
    }

    private static func averageHabitCompletionRate(habits: [Habit]) -> Double? {
        guard !habits.isEmpty else { return nil }
        let repo = HabitRepository.shared
        let rates = habits.map { habit in
            let stats = repo.getCompletionStats(for: habit, days: 14)
            return stats.expectedCount > 0 ? (Double(stats.completedCount) / Double(stats.expectedCount)) * 100 : 0
        }
        return rates.reduce(0, +) / Double(rates.count)
    }
}
