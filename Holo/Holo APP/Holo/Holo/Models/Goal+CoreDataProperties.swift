//
//  Goal+CoreDataProperties.swift
//  Holo
//
//  目标实体属性、便捷属性、工厂方法
//

import Foundation
import CoreData

extension Goal {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var summary: String?
    @NSManaged var domain: String
    @NSManaged var desiredOutcome: String?
    @NSManaged var motivation: String?
    @NSManaged var status: String
    @NSManaged var deadline: Date?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var completedAt: Date?
    @NSManaged var source: String
    @NSManaged var allowAIContext: Bool
    @NSManaged var lastInsightSummary: String?
    @NSManaged var tasks: NSSet?
    @NSManaged var habits: NSSet?

    var goalStatus: GoalStatus {
        get { GoalStatus(rawValue: status) ?? .active }
        set {
            status = newValue.rawValue
            if newValue == .completed, completedAt == nil {
                completedAt = Date()
            }
            if newValue != .completed {
                completedAt = nil
            }
            updatedAt = Date()
        }
    }

    var goalDomain: GoalDomain {
        get { GoalDomain(rawValue: domain) ?? .other }
        set {
            domain = newValue.rawValue
            updatedAt = Date()
        }
    }

    var sortedTasks: [TodoTask] {
        (tasks?.allObjects as? [TodoTask] ?? [])
            .filter { !$0.deletedFlag && !$0.archived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var sortedHabits: [Habit] {
        (habits?.allObjects as? [Habit] ?? [])
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    static func create(
        in context: NSManagedObjectContext,
        title: String,
        summary: String?,
        domain: GoalDomain,
        desiredOutcome: String?,
        motivation: String?,
        deadline: Date?,
        allowAIContext: Bool
    ) -> Goal {
        let goal = Goal(context: context)
        goal.id = UUID()
        goal.title = title
        goal.summary = summary
        goal.domain = domain.rawValue
        goal.desiredOutcome = desiredOutcome
        goal.motivation = motivation
        goal.status = GoalStatus.active.rawValue
        goal.deadline = deadline
        goal.createdAt = Date()
        goal.updatedAt = Date()
        goal.completedAt = nil
        goal.source = "holoAI"
        goal.allowAIContext = allowAIContext
        goal.lastInsightSummary = nil
        return goal
    }
}
