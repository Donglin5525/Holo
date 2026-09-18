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

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        registerCloudSyncRefreshIfNeeded()
    }

    private convenience init() {
        self.init(context: CoreDataStack.shared.viewContext)
    }

    // MARK: - iCloud 远程变更刷新

    /// 新设备上 CloudKit 后台导入晚于首次加载：goalDataDidChange 只在本地写入时发，
    /// 不监听远程变更会让目标列表停在空态。订阅统一中继，防抖后重拉并广播。
    private var cloudSyncObserver: NSObjectProtocol?

    private func registerCloudSyncRefreshIfNeeded() {
        guard cloudSyncObserver == nil else { return }
        cloudSyncObserver = CloudImportRelay.shared.addObserver { [weak self] in
            Task { @MainActor in self?.reloadAfterCloudSync() }
        }
    }

    private func reloadAfterCloudSync() {
        loadGoals()
        NotificationCenter.default.post(name: .goalDataDidChange, object: nil)
    }

    func loadGoals() {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [
            NSSortDescriptor(key: "status", ascending: true),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        goals = DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    func activeGoalsForAI(limit: Int) -> [Goal] {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ AND allowAIContext == YES AND deletedAt == nil",
            GoalStatus.active.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = limit
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 获取指定时间段内完成的目标数量（AI 分析用）
    func completedGoalsCount(from start: Date, to end: Date) -> Int {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@ AND completedAt >= %@ AND completedAt <= %@ AND deletedAt == nil",
            GoalStatus.completed.rawValue,
            start as CVarArg,
            end as CVarArg
        )
        return (try? context.count(for: request)) ?? 0
    }

    func findGoal(by id: UUID) -> Goal? {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// 活跃目标（实时查询）：意图匹配等非 UI 链路使用，
    /// 不依赖 loadGoals 的 UI 缓存（用户可能整个会话都没进过目标列表）
    func activeGoals() -> [Goal] {
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "status == %@ AND deletedAt == nil", GoalStatus.active.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
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

// MARK: - 无保存构造器（原子提交事务内调用，§2.4）

extension GoalRepository {

    /// 构造任务并挂到目标：不保存、不发通知（保存成功后统一发）
    @discardableResult
    static func makeTask(from draft: GoalTaskDraft, goal: Goal, in context: NSManagedObjectContext) -> TodoTask {
        let task = TodoTask.create(
            in: context,
            title: draft.title,
            desc: draft.note,
            list: nil,
            priority: TaskPriority(rawValue: Int16(draft.priority ?? 1)) ?? .medium,
            dueDate: GoalWorkshopCommitService.parseDay(draft.dueDateText),
            isAllDay: true,
            reminders: nil,
            plannedStart: nil,
            plannedEnd: nil
        )
        task.goal = goal
        return task
    }

    /// 构造习惯并挂到目标：不保存、不入看板（保存成功后统一入）
    @discardableResult
    static func makeHabit(from draft: GoalHabitDraft, goal: Goal, in context: NSManagedObjectContext) -> Habit {
        let request = NSFetchRequest<Habit>(entityName: "Habit")
        let maxSortOrder = (try? context.count(for: request)) != nil
            ? ((try? context.fetch(request))?.map { $0.sortOrder }.max() ?? -1)
            : -1
        let habit = Habit.create(
            in: context,
            name: draft.name,
            icon: "target",
            color: "#5B8CFF",
            type: draft.type == "numeric" ? .numeric : .checkIn,
            frequency: draft.resolvedFrequency,
            targetCount: draft.targetCount,
            targetValue: draft.targetValue,
            unit: draft.unit,
            aggregationType: .sum,
            isBadHabit: draft.isBadHabit ?? (draft.successRule == HabitSuccessRule.stayBelowTarget.rawValue),
            sortOrder: maxSortOrder + 1,
            reminderMode: .follow,
            reminderTime: (hour: 9, minute: 0)
        )
        habit.goal = goal
        return habit
    }
}

// MARK: - Draft Save

struct GoalDraftSaveResult {
    let goal: Goal
    let createdTaskCount: Int
    let createdHabitCount: Int
}

extension GoalRepository {
    /// 草案落库：单事务提交（Goal/任务/习惯一次 save），失败不落半套数据。
    /// 旧手建与旧 AI 草案经此复用目标共创的原子提交（§2.4）。
    @discardableResult
    func saveDraft(
        _ draft: GoalDraft,
        allowAIContext: Bool,
        source: String = "holoAI"
    ) throws -> GoalDraftSaveResult {
        let receipt = try GoalWorkshopCommitService.performCommit(
            draft: draft,
            allowAIContext: allowAIContext,
            source: source,
            sourceSessionID: nil,
            successEvidence: "",
            assumptions: [],
            selectedRouteTitle: nil,
            in: context
        )
        // 幂等重放（同 sourceSessionID 已存在）：返回既有目标，不重复创建
        guard !receipt.wasIdempotentReplay, let goal = findGoal(by: receipt.goalID) else {
            if let goal = findGoal(by: receipt.goalID) {
                return GoalDraftSaveResult(goal: goal, createdTaskCount: 0, createdHabitCount: 0)
            }
            throw GoalWorkshopCommitService.CommitError.saveFailed("保存后读取目标失败")
        }
        TodoRepository.shared.loadActiveTasks()
        HabitRepository.shared.loadActiveHabits()
        loadGoals()

        return GoalDraftSaveResult(goal: goal, createdTaskCount: receipt.createdTaskCount, createdHabitCount: receipt.createdHabitCount)
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
        request.predicate = NSPredicate(format: "goalId == %@ AND deletedAt == nil", goal.id as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
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
