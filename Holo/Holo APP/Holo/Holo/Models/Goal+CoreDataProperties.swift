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
    @NSManaged var iconEmoji: String?
    @NSManaged var desiredOutcome: String?
    @NSManaged var motivation: String?
    @NSManaged var status: String
    @NSManaged var deadline: Date?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var completedAt: Date?
    @NSManaged var source: String
    @NSManaged var allowAIContext: Bool
    @NSManaged var proactiveNudge: Bool
    @NSManaged var lastInsightSummary: String?
    @NSManaged var tasks: NSSet?
    @NSManaged var habits: NSSet?

    // MARK: 量化目标字段（三期 3a）
    @NSManaged var goalKind: String
    @NSManaged var metricUnit: String?
    @NSManaged var targetValue: NSNumber?
    @NSManaged var baselineValue: NSNumber?
    @NSManaged var baselineDate: Date?
    @NSManaged var metricSource: String?
    @NSManaged var sourceHabitId: UUID?
    @NSManaged var ledgerScope: String?

    /// 大图标位展示值：用户手选 emoji > 领域默认 emoji
    var displayIcon: String {
        if let chosen = iconEmoji, !chosen.isEmpty { return chosen }
        return goalDomain.defaultEmoji
    }

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

    // MARK: 量化目标便捷属性

    var goalKindEnum: GoalKind {
        get { GoalKind(rawValue: goalKind) ?? .process }
        set { goalKind = newValue.rawValue }
    }

    /// 是否量化目标（累积型/达标型）；旧数据 goalKind 为空，回退过程型
    var isQuantitative: Bool { goalKindEnum != .process }

    var metricSourceEnum: GoalMetricSource {
        get { GoalMetricSource(rawValue: metricSource ?? "") ?? .manual }
        set { metricSource = newValue.rawValue }
    }

    /// 目标数值（Double 便捷形式，写法对齐 Habit.targetValueDouble）
    var metricTargetValueDouble: Double? {
        get { targetValue?.doubleValue }
        set { targetValue = newValue.map { NSNumber(value: $0) } }
    }

    /// 达标型基线（Double 便捷形式）
    var baselineValueDouble: Double? {
        get { baselineValue?.doubleValue }
        set { baselineValue = newValue.map { NSNumber(value: $0) } }
    }

    /// 数值单位展示文本
    var metricUnitText: String { metricUnit ?? "" }

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
        allowAIContext: Bool,
        proactiveNudge: Bool = true
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
        goal.proactiveNudge = proactiveNudge
        goal.lastInsightSummary = nil
        goal.goalKindEnum = .process
        return goal
    }
}
