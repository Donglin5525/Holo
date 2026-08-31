//
//  LifePlanRepository.swift
//  Holo
//
//  LifePlan 计划台账仓库：状态机、确认写回、撤销、滚动对账。
//  状态机：plan = draft→active→completed/superseded；action = proposed→accepted/rejected/completed/expired。
//  周期归属以生成时刻为准；同周期重生成 version+1，旧版整体 superseded。
//

import Foundation
import CoreData
import Combine

@MainActor
final class LifePlanRepository: ObservableObject {

    static let shared = LifePlanRepository()
    private init() {}

    @Published private(set) var lastConfirmedUndoToken: PlanUndoToken?

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    // MARK: - 周期

    /// 本周周期（ISO8601，周一起始）
    nonisolated static func currentWeekPeriod(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        var cal = calendar
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let end = min(
            cal.date(byAdding: .day, value: 7, to: start)?.addingTimeInterval(-1) ?? now,
            now.addingTimeInterval(60 * 60 * 24 * 365)
        ).endOfMinute
        return (start, end)
    }

    // MARK: - 生成落库

    /// 生成结果落库：滚动旧计划 → 建新计划 → 证据引用登记 → PlanRun 记录。
    /// - Parameters:
    ///   - payload: LLM 结构化输出（已过 schema 校验）
    ///   - evidenceReferences: Agent 分析的证据引用全集（用于逐条锚定与 plan 级保护）
    func saveGeneratedPlan(
        payload: LifePlanGenerationPayload,
        jobID: String,
        budget: PlanConsumedBudget?,
        evidenceSummaries: [(id: String, summary: String)],
        trigger: String = "weeklyPlanning",
        now: Date = Date()
    ) throws -> LifePlanSnapshot {
        let period = Self.currentWeekPeriod(now: now)

        // 同周期重生成：旧 active → superseded，版本递增
        let previousPlans = fetchPlanMOs(periodStart: period.start, status: "active")
        var version: Int16 = 1
        for old in previousPlans {
            old.status = "superseded"
            old.updatedAt = now
            version = max(version, old.version + 1)
        }

        let plan = LifePlanMO(context: context)
        plan.id = UUID()
        plan.scope = "week"
        plan.periodStart = period.start
        plan.periodEnd = period.end
        plan.status = "active"
        plan.constraintSummary = payload.constraintSummary
        plan.snapshotCutoffAt = now
        plan.version = version
        plan.trigger = trigger
        plan.dataSufficient = true
        plan.createdAt = now
        plan.updatedAt = now

        // 优先结果：证据 hint 与 Agent 证据摘要做包含匹配锚定
        for (index, priority) in payload.priorities.enumerated() {
            let mo = PlanPriorityMO(context: context)
            mo.id = UUID()
            mo.planID = plan.id
            mo.outcome = priority.outcome
            mo.whyNow = priority.whyNow
            mo.evidenceIDsJSON = encodeJSON(
                matchEvidenceIDs(hints: priority.evidenceHints, evidenceSummaries: evidenceSummaries)
            )
            mo.priorityRank = Int16(index + 1)
            mo.userDecision = "pending"
            mo.createdAt = now
            mo.updatedAt = now
        }

        // 行动卡
        for (index, action) in payload.actions.enumerated() {
            let mo = PlanActionMO(context: context)
            mo.id = UUID()
            mo.planID = plan.id
            mo.type = action.type
            let taskDraft = action.type == "task"
                ? GoalTaskDraft(id: UUID().uuidString, isSelected: true, title: action.title, dueDateText: nil, priority: nil, note: action.note)
                : nil
            let habitDraft = action.type == "habit"
                ? GoalHabitDraft(id: UUID().uuidString, isSelected: true, name: action.title, frequency: HabitFrequency.daily.rawValue, targetCount: nil, type: "checkIn", unit: nil, targetValue: nil, isBadHabit: nil, successRule: nil)
                : nil
            mo.draftPayloadJSON = encodeJSON(PlanActionDraftPayload(task: taskDraft, habit: habitDraft))
            mo.expectedBenefit = action.expectedBenefit
            mo.tradeoff = action.tradeoff
            mo.evidenceIDsJSON = "[]"
            mo.requiresConfirmation = true
            mo.status = "proposed"
            mo.sortOrder = Int16(index)
            mo.createdAt = now
            mo.updatedAt = now
        }

        // PlanRun：自包含成本记录
        let run = PlanRunMO(context: context)
        run.id = UUID()
        run.planID = plan.id
        run.jobID = jobID
        run.trigger = trigger
        run.inputSnapshotVersion = version
        run.consumedBudgetJSON = budget.map { encodeJSON($0) }
        run.resultStatus = "completed"
        run.createdAt = now

        try context.save()

        // 证据引用登记（防 30 天回收；失败不阻塞计划落库）
        let allEvidenceIDs = evidenceSummaries.map(\.id)
        if !allEvidenceIDs.isEmpty {
            let planIDValue = plan.id.uuidString
            let ledger = HoloEvidenceLedger()
            Task.detached { [allEvidenceIDs, planIDValue] in
                try? await ledger.registerLifePlanReferences(planID: planIDValue, evidenceIDs: allEvidenceIDs)
            }
        }

        // 刚落库的对象就在当前 context 内存中，直接构建快照；
        // 不再重新走 fetch（磁盘满/store 忙等瞬时读故障会把已成功落库的计划变成闪退）
        return buildSnapshot(plan)
    }

    /// 降级运行也记录（schema 校验失败 → 普通分析文本）
    func recordDegradedRun(jobID: String, budget: PlanConsumedBudget?, now: Date = Date()) {
        let run = PlanRunMO(context: context)
        run.id = UUID()
        run.planID = UUID()
        run.jobID = jobID
        run.trigger = "weeklyPlanning"
        run.inputSnapshotVersion = 0
        run.consumedBudgetJSON = budget.map { encodeJSON($0) }
        run.resultStatus = "failedDegraded"
        run.createdAt = now
        try? context.save()
    }

    // MARK: - 状态机推进

    /// 过期处理：periodEnd 已过的 active → completed；其未决行动卡 → expired。
    /// 在计划卡渲染前与新计划生成前调用。
    func supersedeExpiredPlans(now: Date = Date()) {
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSPredicate(format: "status == %@ AND periodEnd < %@", "active", now as NSDate)
        guard let expired = try? context.fetch(request), !expired.isEmpty else { return }
        for plan in expired {
            plan.status = "completed"
            plan.updatedAt = now
            expireProposedActions(planID: plan.id, now: now)
        }
        try? context.save()
    }

    private func expireProposedActions(planID: UUID, now: Date) {
        let request = NSFetchRequest<PlanActionMO>(entityName: "PlanActionMO")
        request.predicate = NSPredicate(format: "planID == %@ AND status == %@", planID as CVarArg, "proposed")
        for action in (try? context.fetch(request)) ?? [] {
            action.status = "expired"
            action.updatedAt = now
        }
    }

    // MARK: - 查询

    func fetchActivePlan() -> LifePlanSnapshot? {
        supersedeExpiredPlans()
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "status == %@", "active"),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 1
        guard let plan = (try? context.fetch(request))?.first else { return nil }
        return buildSnapshot(plan)
    }

    /// 最近一份计划（含已完成/被取代，用于「上周台账」滚动注入与对账）
    func fetchLatestPlan() -> LifePlanSnapshot? {
        supersedeExpiredPlans()
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 1
        guard let plan = (try? context.fetch(request))?.first else { return nil }
        return buildSnapshot(plan)
    }

    func snapshot(planID: UUID) -> LifePlanSnapshot? {
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", planID as CVarArg)
        request.fetchLimit = 1
        guard let plan = (try? context.fetch(request))?.first else { return nil }
        return buildSnapshot(plan)
    }

    /// 回放对账：覆盖指定时间范围的计划（periodStart 落在 range 内）
    func fetchPlans(periodStartIn start: Date, _ end: Date) -> [LifePlanSnapshot] {
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "periodStart >= %@ AND periodStart <= %@",
                start as NSDate, end as NSDate
            ),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "periodStart", ascending: false)]
        return ((try? context.fetch(request)) ?? []).map(buildSnapshot)
    }

    /// 长廊统计：总计划数 / 平均每计划接受行动卡数
    func statistics() -> (totalPlans: Int, avgAcceptedActions: Double) {
        let plans = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        plans.predicate = NSPredicate(format: "deletedAt == nil")
        let total = (try? context.count(for: plans)) ?? 0
        guard total > 0 else { return (0, 0) }
        let actions = NSFetchRequest<PlanActionMO>(entityName: "PlanActionMO")
        actions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "status == %@", "accepted"),
            NSPredicate(format: "deletedAt == nil")
        ])
        let accepted = (try? context.count(for: actions)) ?? 0
        return (total, Double(accepted) / Double(total))
    }

    // MARK: - 确认写回

    /// 确认页写回：勾选的优先结果 → Goal；勾选的行动卡 → 任务/习惯（挂到首个创建的 Goal）。
    /// 返回撤销令牌。拒绝的卡同时落反馈。
    @discardableResult
    func confirmPlan(
        planID: UUID,
        selectedPriorityIDs: Set<UUID>,
        selectedActionIDs: Set<UUID>,
        rejections: [(actionID: UUID, reasonTag: String?, freeText: String?)] = [],
        allowAIContext: Bool = true,
        now: Date = Date()
    ) throws -> PlanUndoToken {
        guard let plan = fetchPlanMO(id: planID) else { return PlanUndoToken(goalID: nil, taskIDs: [], habitIDs: []) }

        var token = PlanUndoToken(goalID: nil, taskIDs: [], habitIDs: [])

        // 1) 优先结果 → Goal（取第一个勾选的优先结果建 Goal 承载本批行动）
        var goal: Goal?
        let priorities = fetchPriorityMOs(planID: planID)
        for priority in priorities where selectedPriorityIDs.contains(priority.id) {
            if goal == nil {
                let draft = GoalDraft(
                    id: UUID().uuidString,
                    title: priority.outcome,
                    summary: nil,
                    domain: .life,
                    iconEmoji: nil,
                    desiredOutcome: priority.outcome,
                    motivation: priority.whyNow,
                    deadlineText: nil,
                    tasks: [],
                    habits: [],
                    missingInfoWarnings: []
                )
                goal = try GoalRepository.shared.createGoal(from: draft, allowAIContext: allowAIContext)
                token.goalID = goal?.id
            }
            priority.userDecision = "accepted"
            priority.goalID = goal?.id
            priority.updatedAt = now
        }
        for priority in priorities where !selectedPriorityIDs.contains(priority.id) {
            priority.userDecision = priority.userDecision == "pending" ? "rejected" : priority.userDecision
        }

        // 2) 行动卡 → 任务 / 习惯（对齐 saveDraft 的默认值约定）
        let actions = fetchActionMOs(planID: planID)
        for action in actions {
            if selectedActionIDs.contains(action.id) {
                let payload = decodePayload(action.draftPayloadJSON)
                if action.type == "task", let taskDraft = payload.task {
                    let task = try TodoRepository.shared.createTask(
                        title: taskDraft.title,
                        description: taskDraft.note
                    )
                    task.goal = goal
                    token.taskIDs.append(task.id)
                } else if action.type == "habit", let habitDraft = payload.habit {
                    let habit = try HabitRepository.shared.createHabit(
                        name: habitDraft.name,
                        icon: "target",
                        color: "#5B8CFF",
                        type: habitDraft.type == "numeric" ? .numeric : .checkIn,
                        frequency: habitDraft.resolvedFrequency,
                        targetCount: habitDraft.targetCount,
                        targetValue: habitDraft.targetValue,
                        unit: habitDraft.unit,
                        isBadHabit: habitDraft.isBadHabit ?? false
                    )
                    habit.goal = goal
                    token.habitIDs.append(habit.id)
                }
                action.status = "accepted"
                action.undoTokenJSON = nil
                action.updatedAt = now
            }
        }
        // 撤销令牌存到每张已接受卡上（任一张可触发整批撤销）
        if token.goalID != nil || !token.taskIDs.isEmpty || !token.habitIDs.isEmpty {
            let tokenJSON = encodeJSON(token)
            for action in actions where selectedActionIDs.contains(action.id) {
                action.undoTokenJSON = tokenJSON
            }
            lastConfirmedUndoToken = token
        }

        // 3) 拒绝 + 反馈
        for rejection in rejections {
            guard let action = actions.first(where: { $0.id == rejection.actionID }) else { continue }
            action.status = "rejected"
            action.updatedAt = now
            let feedback = PlanFeedbackMO(context: context)
            feedback.id = UUID()
            feedback.actionID = action.id
            feedback.planID = planID
            feedback.decision = "rejected"
            feedback.reasonTag = rejection.reasonTag
            feedback.freeText = rejection.freeText
            feedback.createdAt = now
        }

        plan.updatedAt = now
        try context.save()
        return token
    }

    /// 撤销：删除确认时创建的实体，行动卡回滚为 proposed
    func undoConfirm(planID: UUID, token: PlanUndoToken, now: Date = Date()) throws {
        if let goalID = token.goalID {
            deleteGoal(id: goalID)
        }
        for taskID in token.taskIDs {
            deleteTask(id: taskID)
        }
        for habitID in token.habitIDs {
            deleteHabit(id: habitID)
        }
        for action in fetchActionMOs(planID: planID) where action.status == "accepted" {
            action.status = "proposed"
            action.undoTokenJSON = nil
            action.updatedAt = now
        }
        for priority in fetchPriorityMOs(planID: planID) where priority.goalID != nil {
            priority.userDecision = "pending"
            priority.goalID = nil
            priority.updatedAt = now
        }
        lastConfirmedUndoToken = nil
        try context.save()
    }

    private func deleteGoal(id: UUID) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Goal")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let object = (try? context.fetch(request))?.first {
            context.delete(object)
        }
    }

    private func deleteTask(id: UUID) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let object = (try? context.fetch(request))?.first {
            context.delete(object)
        }
    }

    private func deleteHabit(id: UUID) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Habit")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let object = (try? context.fetch(request))?.first {
            context.delete(object)
        }
    }

    // MARK: - 滚动对账（上一份计划的决策 + 自动回读真实完成状态）

    /// 生成新计划时注入的上周台账：完成状态通过 goalID/undoToken 回查任务/习惯真实状态，
    /// 不依赖用户手动打卡。
    func previousPlanContext(now: Date = Date()) -> LifePlanPreviousPlanContext? {
        guard let latest = fetchLatestPlan(),
              latest.createdAt < now else { return nil }
        var context = LifePlanPreviousPlanContext(
            periodStart: latest.periodStart,
            periodEnd: latest.periodEnd,
            priorities: [],
            actions: []
        )
        for priority in latest.priorities {
            context.priorities.append(.init(
                outcome: priority.outcome,
                userDecision: priority.userDecision ?? "pending",
                goalID: priority.goalID
            ))
        }
        let feedbacks = fetchFeedbacks(planID: latest.id)
        for action in latest.actions {
            var taskCompleted: Bool?
            if action.status == "accepted" || action.status == "completed" {
                taskCompleted = reconcileActionCompletion(actionID: action.id)
            }
            let rejectReason = feedbacks
                .first { $0.actionID == action.id }?
                .reasonTag
            context.actions.append(.init(
                title: action.payload.displayTitle,
                type: action.type,
                status: action.status,
                rejectReason: rejectReason,
                taskCompleted: taskCompleted
            ))
        }
        return context
    }

    /// 对账单卡：通过 undoToken/taskID 回查任务完成状态；习惯按周期内有打卡近似。
    private func reconcileActionCompletion(actionID: UUID) -> Bool? {
        let request = NSFetchRequest<PlanActionMO>(entityName: "PlanActionMO")
        request.predicate = NSPredicate(format: "id == %@", actionID as CVarArg)
        guard let action = (try? context.fetch(request))?.first else { return nil }
        if action.type == "task" {
            let payload = decodePayload(action.draftPayloadJSON)
            guard let taskDraft = payload.task else { return nil }
            let taskRequest = NSFetchRequest<TodoTask>(entityName: "TodoTask")
            taskRequest.predicate = NSPredicate(format: "title == %@ AND completed == %@", taskDraft.title, true)
            taskRequest.fetchLimit = 1
            return ((try? context.fetch(taskRequest))?.first) != nil
        }
        if action.type == "habit" {
            let payload = decodePayload(action.draftPayloadJSON)
            guard let habitDraft = payload.habit else { return nil }
            let recordRequest = NSFetchRequest<HabitRecord>(entityName: "HabitRecord")
            recordRequest.predicate = NSPredicate(
                format: "habit.name == %@ AND date > %@",
                habitDraft.name, Date().addingTimeInterval(-7 * 24 * 3600) as NSDate
            )
            recordRequest.fetchLimit = 1
            return ((try? context.fetch(recordRequest))?.first) != nil
        }
        return nil
    }

    // MARK: - Private Helpers

    private func fetchPlanMO(id: UUID) -> LifePlanMO? {
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func fetchPlanMOs(periodStart: Date, status: String) -> [LifePlanMO] {
        let request = NSFetchRequest<LifePlanMO>(entityName: "LifePlanMO")
        request.predicate = NSPredicate(
            format: "periodStart == %@ AND status == %@",
            periodStart as NSDate, status
        )
        return (try? context.fetch(request)) ?? []
    }

    private func fetchPriorityMOs(planID: UUID) -> [PlanPriorityMO] {
        let request = NSFetchRequest<PlanPriorityMO>(entityName: "PlanPriorityMO")
        request.predicate = NSPredicate(format: "planID == %@", planID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "priorityRank", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    private func fetchActionMOs(planID: UUID) -> [PlanActionMO] {
        let request = NSFetchRequest<PlanActionMO>(entityName: "PlanActionMO")
        request.predicate = NSPredicate(format: "planID == %@", planID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    private func fetchFeedbacks(planID: UUID) -> [PlanFeedbackMO] {
        let request = NSFetchRequest<PlanFeedbackMO>(entityName: "PlanFeedbackMO")
        request.predicate = NSPredicate(format: "planID == %@", planID as CVarArg)
        return (try? context.fetch(request)) ?? []
    }

    private func buildSnapshot(_ plan: LifePlanMO) -> LifePlanSnapshot {
        LifePlanSnapshot(
            id: plan.id,
            scope: plan.scope,
            periodStart: plan.periodStart,
            periodEnd: plan.periodEnd,
            status: plan.status,
            constraintSummary: plan.constraintSummary,
            version: Int(plan.version),
            trigger: plan.trigger,
            dataSufficient: plan.dataSufficient,
            createdAt: plan.createdAt,
            priorities: fetchPriorityMOs(planID: plan.id).map { mo in
                LifePlanPrioritySnapshot(
                    id: mo.id,
                    outcome: mo.outcome,
                    whyNow: mo.whyNow,
                    evidenceIDs: decodeStringArray(mo.evidenceIDsJSON),
                    priorityRank: Int(mo.priorityRank),
                    userDecision: mo.userDecision,
                    goalID: mo.goalID
                )
            },
            actions: fetchActionMOs(planID: plan.id).map { mo in
                LifePlanActionSnapshot(
                    id: mo.id,
                    type: mo.type,
                    payload: decodePayload(mo.draftPayloadJSON),
                    expectedBenefit: mo.expectedBenefit,
                    tradeoff: mo.tradeoff,
                    evidenceIDs: decodeStringArray(mo.evidenceIDsJSON),
                    requiresConfirmation: mo.requiresConfirmation,
                    status: mo.status,
                    sortOrder: Int(mo.sortOrder)
                )
            }
        )
    }

    private func matchEvidenceIDs(
        hints: [String],
        evidenceSummaries: [(id: String, summary: String)]
    ) -> [String] {
        var matched: [String] = []
        for hint in hints where hint.count >= 4 {
            for evidence in evidenceSummaries
            where evidence.summary.localizedCaseInsensitiveContains(hint) && !matched.contains(evidence.id) {
                matched.append(evidence.id)
            }
        }
        return matched
    }

    private func decodePayload(_ json: String) -> PlanActionDraftPayload {
        (try? JSONDecoder().decode(PlanActionDraftPayload.self, from: Data(json.utf8)))
            ?? PlanActionDraftPayload(task: nil, habit: nil)
    }

    private func decodeStringArray(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

}

private nonisolated extension Date {
    var endOfMinute: Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return calendar.date(from: comps) ?? self
    }
}
