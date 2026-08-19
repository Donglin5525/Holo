//
//  GoalRepository.swift
//  Holo
//
//  目标数据仓库：CRUD、草案落库、状态切换、查询
//

import Foundation
import CoreData
import Combine

// MARK: - 通知名称

extension Notification.Name {
    /// 目标数据变更通知（新增/编辑/删除/关联/状态切换时发送）
    static let goalDataDidChange = Notification.Name("goalDataDidChange")
}

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

    /// 获取指定时间段内完成的目标数量（AI 分析用）
    func completedGoalsCount(from start: Date, to end: Date) -> Int {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ AND completedAt >= %@ AND completedAt <= %@",
            GoalStatus.completed.rawValue,
            start as CVarArg,
            end as CVarArg
        )
        return (try? context.count(for: request)) ?? 0
    }

    func findGoal(by id: UUID) -> Goal? {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// 活跃目标（实时查询）：意图匹配等非 UI 链路使用，
    /// 不依赖 loadGoals 的 UI 缓存（用户可能整个会话都没进过目标列表）
    func activeGoals() -> [Goal] {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "status == %@", GoalStatus.active.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    @discardableResult
    func createGoal(
        from draft: GoalDraft,
        allowAIContext: Bool,
        source: String = "holoAI"
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
        goal.iconEmoji = draft.iconEmoji
        goal.source = source
        applyQuantitativeFields(from: draft, to: goal, now: Date())
        try context.save()
        loadGoals()
        return goal
    }

    /// 把草案中的量化配置落到目标上（创建路径）：
    /// 累积型 baselineDate=创建时刻；达标型基线=用户填写的当前值，起点同样记创建时刻
    private func applyQuantitativeFields(from draft: GoalDraft, to goal: Goal, now: Date) {
        goal.goalKindEnum = draft.goalKind
        guard draft.isQuantitative else { return }
        goal.metricSourceEnum = draft.metricSource
        goal.metricUnit = draft.metricUnit
        goal.metricTargetValueDouble = draft.metricTargetValue
        goal.baselineValueDouble = draft.goalKind == .target ? draft.metricBaselineValue : nil
        goal.sourceHabitId = draft.metricSource == .habit ? draft.sourceHabitId : nil
        goal.baselineDate = now
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

    func updateProactiveNudge(_ goal: Goal, enabled: Bool) throws {
        goal.proactiveNudge = enabled
        goal.updatedAt = Date()
        try context.save()
        loadGoals()
    }

    /// 批量更新目标字段。nil 参数表示不修改该字段。
    /// 量化字段：goalKind 传 .process 会清空全部量化配置（切回过程型）；
    /// metricUnit/metricTargetValue/metricBaselineValue 沿用双层可选约定（.some(nil)=清空）；
    /// metricSource/sourceHabitId 变化视为换口径，累计起点 baselineDate 重置为当前时刻。
    func updateFields(
        _ goal: Goal,
        title: String? = nil,
        summary: String? = nil,
        domain: GoalDomain? = nil,
        iconEmoji: String?? = nil,
        desiredOutcome: String? = nil,
        motivation: String? = nil,
        deadline: Date?? = nil,
        proactiveNudge: Bool? = nil,
        goalKind: GoalKind? = nil,
        metricUnit: String?? = nil,
        metricTargetValue: Double?? = nil,
        metricBaselineValue: Double?? = nil,
        metricSource: GoalMetricSource? = nil,
        sourceHabitId: UUID?? = nil
    ) throws {
        if let title { goal.title = title }
        if let summary { goal.summary = summary }
        if let domain { goal.goalDomain = domain }
        if let iconEmoji { goal.iconEmoji = iconEmoji }
        if let desiredOutcome { goal.desiredOutcome = desiredOutcome }
        if let motivation { goal.motivation = motivation }
        if let deadline { goal.deadline = deadline }
        if let proactiveNudge { goal.proactiveNudge = proactiveNudge }
        if let goalKind {
            goal.goalKindEnum = goalKind
            if goalKind == .process {
                goal.metricSource = nil
                goal.metricUnit = nil
                goal.targetValue = nil
                goal.baselineValue = nil
                goal.baselineDate = nil
                goal.sourceHabitId = nil
            } else if goal.baselineDate == nil {
                // 过程型转量化：以转换时刻为累计/速率起点
                goal.baselineDate = Date()
            }
        }
        if let metricUnit { goal.metricUnit = metricUnit }
        if let metricTargetValue { goal.metricTargetValueDouble = metricTargetValue }
        if let metricBaselineValue { goal.baselineValueDouble = metricBaselineValue }

        // 换源/换源习惯：口径变了，旧累计起点无意义，重置为当前时刻
        let sourceChanged = (metricSource != nil && metricSource != goal.metricSourceEnum)
            || (sourceHabitId != nil && sourceHabitId != goal.sourceHabitId)
        if let metricSource { goal.metricSourceEnum = metricSource }
        if let sourceHabitId { goal.sourceHabitId = sourceHabitId }
        if sourceChanged && goal.isQuantitative {
            goal.baselineDate = Date()
        }
        if goal.isQuantitative && goal.metricSource == nil {
            goal.metricSource = GoalMetricSource.manual.rawValue
        }
        goal.updatedAt = Date()
        try context.save()
        loadGoals()
    }

    func linkTask(_ task: TodoTask, to goal: Goal) throws {
        task.goal = goal
        goal.updatedAt = Date()
        try context.save()
        TodoRepository.shared.loadActiveTasks()
        loadGoals()
    }

    func unlinkTask(_ task: TodoTask, from goal: Goal) throws {
        if task.goal == goal { task.goal = nil }
        goal.updatedAt = Date()
        try context.save()
        TodoRepository.shared.loadActiveTasks()
        loadGoals()
    }

    func linkHabit(_ habit: Habit, to goal: Goal) throws {
        habit.goal = goal
        goal.updatedAt = Date()
        try context.save()
        HabitRepository.shared.loadActiveHabits()
        loadGoals()
    }

    func unlinkHabit(_ habit: Habit, from goal: Goal) throws {
        if habit.goal == goal { habit.goal = nil }
        goal.updatedAt = Date()
        try context.save()
        HabitRepository.shared.loadActiveHabits()
        loadGoals()
    }

    func deleteGoal(_ goal: Goal) throws {
        // 手动记录与目标无 Core Data 关系，删除目标时一并清理，避免孤儿数据
        for log in getMetricLogs(for: goal) {
            context.delete(log)
        }
        context.delete(goal)
        try context.save()
        loadGoals()
    }

    func deleteGoal(id: UUID) throws {
        guard let goal = findGoal(by: id) else { return }
        try deleteGoal(goal)
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
        allowAIContext: Bool,
        source: String = "holoAI"
    ) throws -> GoalDraftSaveResult {
        let goal = try createGoal(from: draft, allowAIContext: allowAIContext, source: source)

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

// MARK: - 量化目标手动记录（GoalMetricLog，仅 manual 源）
// 结构对齐 HabitRepository 的 HabitRecord 方法

extension GoalRepository {

    /// 记一笔。写完后 touch goal.updatedAt 触发详情页 ObservedObject 刷新，
    /// 进度每次展示时实时重算，无需任何缓存同步
    @discardableResult
    func addMetricLog(for goal: Goal, value: Double, date: Date = Date(), note: String? = nil) throws -> GoalMetricLog {
        let log = GoalMetricLog(context: context)
        log.id = UUID()
        log.goalId = goal.id
        log.date = date
        log.value = value
        log.note = note
        log.createdAt = Date()
        goal.updatedAt = Date()
        try context.save()
        loadGoals()
        return log
    }

    /// 指定目标的全部手动记录（date 降序，首条即最新）
    func getMetricLogs(for goal: Goal) -> [GoalMetricLog] {
        let request = GoalMetricLog.fetchRequest()
        request.predicate = NSPredicate(format: "goalId == %@", goal.id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 最新一条记录（达标型当前水平用）
    func latestMetricLog(for goal: Goal) -> GoalMetricLog? {
        getMetricLogs(for: goal).first
    }

    /// 删除一条记录；进度实时重算
    func deleteMetricLog(_ log: GoalMetricLog, for goal: Goal) throws {
        context.delete(log)
        goal.updatedAt = Date()
        try context.save()
        loadGoals()
    }
}
