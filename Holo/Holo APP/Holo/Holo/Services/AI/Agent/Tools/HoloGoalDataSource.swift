//
//  HoloGoalDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — 生产目标数据源
//  复用 GoalRepository 的活跃目标查询，在 MainActor 内转为值类型快照。
//  Core Data 实体（Goal/TodoTask/Habit）绝不跨出 MainActor.run 闭包。
//

import Foundation

struct HoloDefaultGoalDataSource: HoloGoalDataSource {

    func activeGoals(timeRange: HoloAgentTimeRange?) async -> [HoloGoalToolRecord] {
        // 活跃目标是长期对象，不按 timeRange 过滤；activeGoalsForAI 已内置
        // status == active AND allowAIContext == YES 过滤（GoalRepository.swift:36）。
        _ = timeRange
        return await MainActor.run {
            GoalRepository.shared.activeGoalsForAI(limit: 20).map { goal in
                HoloGoalToolRecord(
                    id: goal.id.uuidString,
                    title: goal.title,
                    domain: goal.domain,
                    deadline: goal.deadline,
                    desiredOutcome: goal.desiredOutcome,
                    updatedAt: goal.updatedAt,
                    linkedTasks: goal.sortedTasks.map { task in
                        HoloGoalLinkedTaskSnapshot(
                            id: task.id.uuidString,
                            title: task.title,
                            completed: task.completed,
                            dueDate: task.dueDate
                        )
                    },
                    linkedHabits: goal.sortedHabits.map { habit in
                        HoloGoalLinkedHabitSnapshot(
                            id: habit.id.uuidString,
                            name: habit.name
                        )
                    }
                )
            }
        }
    }
}
