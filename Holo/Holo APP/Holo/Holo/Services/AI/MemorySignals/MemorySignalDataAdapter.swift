//
//  MemorySignalDataAdapter.swift
//  Holo
//
//  从 Repository 层采集数据并转换为 Memory Observer 信号输入
//

import Foundation

enum MemorySignalDataAdapter {

    // MARK: - Habit → HabitFocusSummary

    static func buildHabitFocusSummaries() -> [HabitFocusSummary] {
        let repo = HabitRepository.shared
        repo.loadActiveHabits()
        let habits = repo.activeHabits
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 当前窗口：过去 14 天
        guard let currentStart = calendar.date(byAdding: .day, value: -14, to: today) else { return [] }
        let currentRange = currentStart...today

        // 上一窗口：再往前 14 天
        guard let previousStart = calendar.date(byAdding: .day, value: -14, to: currentStart) else { return [] }
        let previousRange = previousStart...currentStart

        return habits.compactMap { habit in
            let current = repo.evaluatePerformance(for: habit, in: currentRange)
            let previous = repo.evaluatePerformance(for: habit, in: previousRange)
            let streak = repo.calculateStreakInfo(for: habit)
            let signal = HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: habit.goal?.title,
                profileContext: nil
            )

            return HabitFocusSummary(
                habitName: habit.name,
                signal: signal,
                current: current,
                previous: previous,
                currentStreak: streak.value,
                goalTitle: habit.goal?.title
            )
        }
    }

    // MARK: - Goal → GoalProgressInput

    static func buildGoalProgressInputs() -> [GoalProgressInput] {
        let goals = GoalRepository.shared.activeGoalsForAI(limit: 10)

        return goals.compactMap { goal in
            let tasks = goal.sortedTasks
            let completed = tasks.filter { $0.completed }.count

            return GoalProgressInput(
                id: goal.id.uuidString,
                title: goal.title,
                deadline: goal.deadline,
                createdAt: goal.createdAt,
                completedAt: goal.completedAt,
                status: goal.status,
                taskTotal: tasks.count,
                taskCompleted: completed
            )
        }
    }
}
