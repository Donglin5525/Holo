//
//  GoalRepository.swift
//  Holo
//
//  目标数据仓库：CRUD、草案落库、状态切换、查询
//

import Foundation
import CoreData
import Combine

@MainActor
final class GoalRepository: ObservableObject {
    static let shared = GoalRepository()

    @Published private(set) var goals: [Goal] = []

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    private init() {}

    func loadGoals() {
        let request = Goal.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "status", ascending: true),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        goals = (try? context.fetch(request)) ?? []
    }

    func activeGoalsForAI(limit: Int) -> [Goal] {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ AND allowAIContext == YES",
            GoalStatus.active.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = limit
        return (try? context.fetch(request)) ?? []
    }

    func findGoal(by id: UUID) -> Goal? {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    @discardableResult
    func createGoal(
        from draft: GoalDraft,
        allowAIContext: Bool
    ) throws -> Goal {
        let goal = Goal.create(
            in: context,
            title: draft.title,
            summary: draft.summary,
            domain: draft.domain,
            desiredOutcome: draft.desiredOutcome,
            motivation: draft.motivation,
            deadline: parseDate(draft.deadlineText),
            allowAIContext: allowAIContext
        )
        try context.save()
        loadGoals()
        return goal
    }

    func updateStatus(_ goal: Goal, status: GoalStatus) throws {
        goal.goalStatus = status
        try context.save()
        loadGoals()
    }

    func updateAIContext(_ goal: Goal, allow: Bool) throws {
        goal.allowAIContext = allow
        goal.updatedAt = Date()
        try context.save()
        loadGoals()
    }

    func deleteGoal(_ goal: Goal) throws {
        context.delete(goal)
        try context.save()
        loadGoals()
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

// MARK: - Draft Save

struct GoalDraftSaveResult {
    let goal: Goal
    let createdTaskCount: Int
    let createdHabitCount: Int
}

extension GoalRepository {
    @discardableResult
    func saveDraft(
        _ draft: GoalDraft,
        allowAIContext: Bool
    ) throws -> GoalDraftSaveResult {
        let goal = try createGoal(from: draft, allowAIContext: allowAIContext)

        var taskCount = 0
        for taskDraft in draft.tasks where taskDraft.isSelected {
            let task = try TodoRepository.shared.createTask(
                title: taskDraft.title,
                description: taskDraft.note,
                priority: TaskPriority(rawValue: Int16(taskDraft.priority ?? 1)) ?? .medium,
                dueDate: parseDate(taskDraft.dueDateText),
                isAllDay: true
            )
            task.goal = goal
            taskCount += 1
        }

        var habitCount = 0
        for habitDraft in draft.habits where habitDraft.isSelected {
            let habit = try HabitRepository.shared.createHabit(
                name: habitDraft.name,
                icon: "target",
                color: "#5B8CFF",
                type: habitDraft.type == "numeric" ? .numeric : .checkIn,
                frequency: habitDraft.resolvedFrequency,
                targetCount: habitDraft.targetCount,
                targetValue: habitDraft.targetValue,
                unit: habitDraft.unit,
                isBadHabit: habitDraft.isBadHabit ?? (habitDraft.successRule == HabitSuccessRule.stayBelowTarget.rawValue)
            )
            habit.goal = goal
            habitCount += 1
        }

        goal.updatedAt = Date()
        try context.save()
        TodoRepository.shared.loadActiveTasks()
        HabitRepository.shared.loadActiveHabits()
        loadGoals()

        return GoalDraftSaveResult(goal: goal, createdTaskCount: taskCount, createdHabitCount: habitCount)
    }
}
