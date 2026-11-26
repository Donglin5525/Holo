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
        if draft.metricSource == .ledger {
            goal.ledgerScopePayload = draft.ledgerScope
        } else if draft.metricSource == .healthKit {
            goal.healthMetricKindEnum = draft.healthMetricKind
        } else {
            goal.ledgerScope = nil
        }
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
    /// metricSource/sourceHabitId/ledgerScope 变化视为换口径，累计起点 baselineDate 重置为当前时刻。
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
        sourceHabitId: UUID?? = nil,
        ledgerScope: GoalLedgerScopePayload?? = nil,
        healthMetricKind: GoalHealthMetricKind?? = nil,
        metricComparison: GoalResultComparison? = nil,
        metricComparisonIsExplicit: Bool? = nil,
        metricStartDate: Date?? = nil,
        expectedPlanRevisionID: UUID? = nil
    ) throws {
        let priorRow = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)
        if let expectedPlanRevisionID, priorRow?.id != expectedPlanRevisionID {
            throw GoalAdjustmentCommitError.validation("计划已被更新，请重新打开后核对")
        }
        if case .unsupportedFuture = priorRow?.planPayloadDecodeResult {
            throw GoalAdjustmentCommitError.validation("计划来自更新版本，当前不能覆盖")
        }
        let priorAttributes = goal.dictionaryWithValues(forKeys: Array(goal.entity.attributesByName.keys))
        var insertedRevision: GoalPlanRevisionMO?
        let previousKind = goal.goalKindEnum
        let previousSource = goal.metricSourceEnum
        let previousHabitID = goal.sourceHabitId
        let previousHealthKind = goal.healthMetricKindEnum
        let previousPlanSource = priorRow?.planPayloadV2?.resultSource
        let previousLedgerScope = goal.ledgerScopePayload ?? previousPlanSource?.ledgerScope
        let nextUnit = metricUnit ?? goal.metricUnit
        if (goalKind ?? previousKind) != .process, (metricSource ?? previousSource) == .manual,
           previousSource != .manual || !HoloQuantityUnit.sameStorageUnit(previousPlanSource?.unit ?? goal.metricUnit, nextUnit) {
            let logs = GoalMetricLog.fetchRequest()
            logs.predicate = NSPredicate(format: "goalId == %@", goal.id as CVarArg)
            logs.fetchLimit = 1
            guard try context.count(for: logs) == 0 else {
                throw GoalAdjustmentCommitError.validation(String(localized: "这个目标已有手动数值记录。请沿用原单位，或用新单位另建目标。"))
            }
        }
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
                goal.ledgerScope = nil
            } else if goal.baselineDate == nil {
                // 过程型转量化：以转换时刻为累计/速率起点
                goal.baselineDate = Date()
            }
        }
        if let metricUnit { goal.metricUnit = metricUnit }
        if let metricTargetValue { goal.metricTargetValueDouble = metricTargetValue }
        if let metricBaselineValue { goal.baselineValueDouble = metricBaselineValue }

        // 换源/换源习惯/换账本范围：口径变了，旧累计起点无意义，重置为当前时刻
        let startChanged = metricStartDate.map { $0 != goal.baselineDate } ?? false
        let sourceChanged = (goalKind != nil && goalKind != previousKind)
            || (metricSource != nil && metricSource != previousSource)
            || (sourceHabitId.map { $0 != previousHabitID } ?? false)
            || (healthMetricKind.map { $0 != previousHealthKind } ?? false)
            || (ledgerScope.map { $0 != previousLedgerScope } ?? false)
        if let metricSource { goal.metricSourceEnum = metricSource }
        if let sourceHabitId { goal.sourceHabitId = sourceHabitId }
        if let ledgerScope, goal.metricSourceEnum != .healthKit { goal.ledgerScopePayload = ledgerScope }
        if goal.metricSourceEnum == .healthKit {
            if let healthMetricKind { goal.healthMetricKindEnum = healthMetricKind }
            if sourceChanged { goal.baselineValueDouble = nil }
        }
        if goal.isQuantitative && (sourceChanged || startChanged) {
            goal.baselineDate = goal.goalKindEnum == .cumulative ? metricStartDate.flatMap { $0 } ?? Date() : Date()
        }
        if goal.isQuantitative && goal.metricSource == nil {
            goal.metricSource = GoalMetricSource.manual.rawValue
        }
        goal.updatedAt = Date()
        do {
            if priorRow?.planPayloadV2 != nil || metricComparison != nil {
                var next = priorRow?.planPayloadV2 ?? GoalPlanResolver.legacyBaselinePayload(goal: goal, legacySummary: nil, now: Date())
                let old = priorRow?.planPayloadV2
                next.intent.deadline = goal.deadline
                next.intent.successCriteria = goal.desiredOutcome
                if !goal.isQuantitative { next.resultSource = nil }
                else if sourceChanged || next.resultSource == nil || (goal.metricSourceEnum == .healthKit && next.resultSource?.sourceType != .healthKit) {
                    next.resultSource = GoalPlanResolver.legacyResultSource(goal: goal)
                } else {
                    next.resultSource?.targetValue = goal.metricTargetValueDouble
                    next.resultSource?.unit = goal.metricUnit
                    next.resultSource?.baselineValue = goal.baselineValueDouble
                    if startChanged {
                        next.resultSource?.baselineObservedAt = goal.baselineDate
                        if next.resultSource?.sourceType == .habit && next.resultSource?.aggregation == .sum {
                            next.resultSource?.countsFromBaseline = true
                        }
                    }
                    if goal.metricSourceEnum == .ledger {
                        next.resultSource?.ledgerScope = goal.ledgerScopePayload
                    }
                }
                if let metricComparison { next.resultSource?.comparison = metricComparison }
                if let metricComparisonIsExplicit { next.resultSource?.comparisonIsExplicit = metricComparisonIsExplicit }
                if sourceChanged {
                    updateResultBindings(in: &next, previous: previousPlanSource)
                }
                if next.resultSource?.sourceType != .ledger { next.fundSchedule = [] }
                if old != next {
                    next.schemaVersion = 3
                    next.basis = GoalPlanDecisionBasisV2(origin: .adjustment, confirmedAt: Date(), selectedChangeSummaries: ["用户编辑目标条件"])
                    insertedRevision = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                        revisionNumber: Int(priorRow?.revisionNumber ?? 0) + 1, baseRevisionID: priorRow?.id, operationID: UUID(), effectiveFrom: Date(), payload: next, legacySummary: nil)
                }
            }
            try context.save()
        } catch {
            if let insertedRevision { context.delete(insertedRevision) }
            goal.setValuesForKeys(priorAttributes)
            throw error
        }
        loadGoals()
    }

    private func updateResultBindings(in plan: inout GoalPlanPayloadV2, previous: GoalPlanResultSourceV2?) {
        let replaced = Set([previous?.sourceID, previous?.ledgerScope?.accountID].compactMap { $0 })
        plan.bindings.removeAll { binding in
            binding.role == .result && !binding.isGoalOwned && binding.entityID.map { replaced.contains($0) } == true
        }
        guard let source = plan.resultSource else { return }
        let type: GoalPlanBindingEntityType
        let id: UUID
        if source.sourceType == .habit, let habitID = source.sourceID {
            type = .habit
            id = habitID
        } else if source.sourceType == .ledger, let accountID = source.ledgerScope?.accountID {
            type = .account
            id = accountID
        } else {
            return
        }
        guard !plan.bindings.contains(where: { $0.isActive && $0.entityType == type && $0.entityID == id }) else { return }
        plan.bindings.append(GoalPlanBindingV2(
            id: GoalPlanBindingV2.stableID(entityType: type, entityID: id), entityType: type,
            entityID: id, role: .result, effectiveFrom: source.baselineObservedAt,
            isGoalOwned: false
        ))
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
        try deleteGoal(goal, deletingOwnedEntities: false)
    }

    /// 删除目标时会被一并删除的「目标创建」实体清单（isGoalOwned 绑定）。
    /// 复用/手动挂进来的旧习惯、旧任务不在其中——它们有自己的生活，只解除关联。
    struct OwnedEntityImpact {
        let ownedHabits: [Habit]
        let ownedTasks: [TodoTask]

        var isEmpty: Bool { ownedHabits.isEmpty && ownedTasks.isEmpty }

        var summaryText: String {
            var parts: [String] = []
            if !ownedHabits.isEmpty {
                parts.append(String(localized: "\(ownedHabits.count) 个习惯"))
            }
            if !ownedTasks.isEmpty {
                parts.append(String(localized: "\(ownedTasks.count) 个任务"))
            }
            return parts.joined(separator: "、")
        }
    }

    /// 读取当前生效计划里的目标专属绑定，解析成真实对象（已删/已归档的跳过）。
    /// 查询全部走本仓库 context——测试注入的独立上下文同样成立，不串 shared 单例的库。
    func ownedEntityImpact(of goal: Goal) -> OwnedEntityImpact {
        guard let row = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context),
              let payload = row.planPayloadV2 else {
            return OwnedEntityImpact(ownedHabits: [], ownedTasks: [])
        }
        let now = Date()
        var habits: [Habit] = []
        var tasks: [TodoTask] = []
        for binding in payload.activeBindings(at: now) where binding.isGoalOwned {
            guard let entityID = binding.entityID else { continue }
            switch binding.entityType {
            case .habit:
                // 自带 deletedAt == nil AND isArchived == NO 过滤
                if let habit = GoalWorkshopCommitService.fetchHabit(id: entityID, in: context) {
                    habits.append(habit)
                }
            case .task:
                let request = TodoTask.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedFlag == NO", entityID as CVarArg)
                request.fetchLimit = 1
                if let task = try? context.fetch(request).first {
                    tasks.append(task)
                }
            case .budget, .account, .fundSchedule:
                continue
            }
        }
        return OwnedEntityImpact(ownedHabits: habits, ownedTasks: tasks)
    }

    /// 删除目标；deletingOwnedEntities = true 时连同目标创建的习惯（硬删，记录级联）
    /// 与任务（软删进回收站，30 天可恢复）一起删除，其余关联实体仅解除关联。
    /// 全程在同一 context 事务内完成；保存成功后再发各模块通知。
    func deleteGoal(_ goal: Goal, deletingOwnedEntities: Bool) throws {
        guard goal.deletedAt == nil else { return }
        let now = Date()
        let impact = deletingOwnedEntities ? ownedEntityImpact(of: goal) : nil
        // 目标创建的任务：整批一个回收站批次（软删标记，与任务模块单删同链路可恢复）
        if let impact, !impact.ownedTasks.isEmpty {
            let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortTitle = title.count > 16 ? String(title.prefix(16)) + "…" : title
            let batch = RecycleBinService.makeSingleItemBatch(
                module: .task,
                summary: String(localized: "删除目标 · \(shortTitle.isEmpty ? String(localized: "无标题") : shortTitle)"),
                context: context,
                now: now
            )
            for task in impact.ownedTasks {
                // 打软删标记后 goal.sortedTasks（过滤 deletedAt）就看不到它了，解绑必须在这里一并做
                task.goal = nil
                task.deletedFlag = true
                task.markDeleted(batchId: batch.id)
                task.updatedAt = now
            }
        }
        // 单条软删（deletedAt != nil, deletedBatchId == nil）：
        // 避免在 NavigationStack 退栈动画完成前 context.delete 触发 Core Data 悬空崩溃，并对齐全库 SoftDeletable 规范。
        for log in getMetricLogs(for: goal) {
            log.deletedAt = now
            log.deletedBatchId = nil
        }
        for task in goal.sortedTasks {
            task.goal = nil
        }
        for habit in goal.sortedHabits {
            habit.goal = nil
        }
        // 目标创建的习惯硬删（与习惯模块单删同语义：记录随 Habit→HabitRecord 级联规则带走）
        var deletedHabitIDs: [UUID] = []
        if let impact {
            for habit in impact.ownedHabits {
                deletedHabitIDs.append(habit.id)
                context.delete(habit)
            }
        }
        if UserDefaults.standard.string(forKey: "holo.today.focusGoalID") == goal.id.uuidString {
            UserDefaults.standard.removeObject(forKey: "holo.today.focusGoalID")
        }
        goal.deletedAt = now
        goal.deletedBatchId = nil
        goal.updatedAt = now
        try context.save()
        loadGoals()
        TodoRepository.shared.loadActiveTasks()
        HabitRepository.shared.loadActiveHabits()
        for habitID in deletedHabitIDs {
            HabitRepository.shared.notifyDataChange(habitId: habitID)
        }
        for taskID in impact?.ownedTasks.map(\.id) ?? [] {
            TodoRepository.shared.notifyTaskChange(.deleted, taskId: taskID)
        }
    }

    func deleteGoal(id: UUID, deletingOwnedEntities: Bool = false) throws {
        guard let goal = findGoal(by: id) else { return }
        try deleteGoal(goal, deletingOwnedEntities: deletingOwnedEntities)
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
            // 聚合语义跟随草案（体重 latest / 时长 sum），不再固定 sum（目标闭环 §6.2）
            aggregationType: draft.resolvedAggregation,
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
    func addMetricLog(
        for goal: Goal, value: Double, date: Date = Date(), note: String? = nil, recordID: UUID? = nil
    ) throws -> GoalMetricLog {
        if let recordID {
            let request = GoalMetricLog.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
            request.fetchLimit = 1
            if let existing = try context.fetch(request).first {
                guard existing.goalId == goal.id, existing.deletedAt == nil else {
                    throw GoalAdjustmentCommitError.validation(String(localized: "这项记录的状态已变化，请重新核对目标。"))
                }
                return existing
            }
        }
        let log = GoalMetricLog(context: context)
        log.id = recordID ?? UUID()
        log.goalId = goal.id
        log.date = date
        log.value = value
        log.note = note
        log.createdAt = Date()
        let previousUpdatedAt = goal.updatedAt
        goal.updatedAt = Date()
        do { try context.save() }
        catch {
            context.delete(log)
            goal.updatedAt = previousUpdatedAt
            throw error
        }
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
