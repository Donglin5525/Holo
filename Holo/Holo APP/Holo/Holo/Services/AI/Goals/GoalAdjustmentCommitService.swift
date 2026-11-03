//
//  GoalAdjustmentCommitService.swift
//  Holo
//
//  目标闭环·修正提交（最终规格 §6.5 / §3.4）
//
//  确认前不改任何对象。确认时：
//  1. 主线程在提交时点重新读取生效版本与依赖事实摘要（不信任界面打开时的缓存）：
//     草案过期、依据变化、基础版本已被替换、同父版本分叉（多设备并发）各自拦停；
//  2. 幂等键 operationID = draftID：重复点按/超时重试/恢复只一次生效，不多建对象、不重复升版；
//  3. 金额/期次等确定性内容在代码内重算（存钱：按提交时点的当前资金重算每期应存，旧建议随之失效）；
//  4. 在指向同一持久化 store 的隔离 context 中写入全部选中变更 + 新计划版本，一次 save，失败整回滚；
//  5. 成功后才发布原模块刷新。
//
//  原意保护（R28）：成果标准/总额/期限变更要求单独确认标志，未确认直接拒绝。
//  共享保护（R30）：只改本目标绑定与要求；共享习惯禁止改名/改口径，不做全局暂停。
//

import Foundation
import CoreData

struct GoalAdjustmentCommitInput {
    let goalID: UUID
    /// 用户在差异单里最终编辑后的草案（取消的操作 isSelected=false 不提交）
    let draft: GoalAdjustmentDraftV2
    /// changeSuccessCriteria 类操作的单独明确确认（差异单里的独立勾选）
    let criteriaChangeConfirmed: Bool
    let now: Date
}

struct GoalAdjustmentCommitReceipt: Equatable {
    let goalID: UUID
    let revisionID: UUID
    let revisionNumber: Int
    let appliedOperationIDs: [String]
    let changedObjectTitles: [String]
    let wasIdempotentReplay: Bool
    /// 金额重算后的每期应存（展示「应用后每期应存」）
    var recomputedPerInstallment: Decimal? = nil
}

enum GoalAdjustmentCommitError: Error, Equatable {
    /// 草案已过期：需重新分析刷新差异
    case draftExpired(expiresAt: Date)
    /// 依赖事实改变（如补记资金）：刷新差异后再确认（R27：旧 3300 建议不能直接采纳）
    case sourceDigestChanged
    /// 基础版本已被替换（本机或他处已提交新版本）
    case baseRevisionChanged(currentRevisionID: UUID)
    /// 同一父版本下已有别的提交子版本：多设备并发分叉，暂停自动应用，待人工合并（R35）
    case concurrentBranchDetected(siblingRevisionIDs: [UUID])
    /// 成果标准/总额/期限变更必须单独确认（R28）
    case separateConfirmationRequired
    case goalMissing
    case validation(String)
    case objectMissing(String)
    /// 同账户同周期已有预算：须复用或改既有，不新建第二份（R32）
    case budgetConflict
    case saveFailed(String)
}

@MainActor
final class GoalAdjustmentCommitService {

    static let shared = GoalAdjustmentCommitService()

    private init() {}

    /// 提交时点在主线程现算的校验值（仍不信任界面打开时的缓存；与后台写入的间隙为毫秒级）
    struct PreparedFacts {
        var freshDigest: String?
        var currentFunds: Decimal?
    }

    func commit(input: GoalAdjustmentCommitInput,
                snapshotBuilder: GoalEvaluationSnapshotBuilder? = nil) async throws -> GoalAdjustmentCommitReceipt {
        let builder = snapshotBuilder ?? .makeDefault()
        let viewContext = CoreDataStack.shared.viewContext

        // 幂等预检（主线程先看一眼，避免无谓地进后台事务）
        if let existing = GoalPlanRevisionStore.revisionRow(operationID: input.draft.draftID, goalID: input.draft.goalID, in: viewContext) {
            return GoalAdjustmentCommitReceipt(goalID: input.draft.goalID, revisionID: existing.id,
                                               revisionNumber: Int(existing.revisionNumber),
                                               appliedOperationIDs: [], changedObjectTitles: [],
                                               wasIdempotentReplay: true)
        }

        let facts = prepareFacts(input: input, snapshotBuilder: builder, in: viewContext)

        let context = CoreDataStack.shared.newBackgroundContext()
        let receipt = try await context.perform {
            try Self.performCommit(input: input, facts: facts, in: context)
        }
        guard !receipt.wasIdempotentReplay else { return receipt }
        await Self.postSaveSideEffects(receipt: receipt)
        return receipt
    }

    /// 依据摘要与当前资金：按报告冻结窗口重建（补记进窗口的历史记录会改变摘要）；
    /// 当前资金另按「现在」读一次供期次重算（R27：确认时点的真实资金）
    private func prepareFacts(input: GoalAdjustmentCommitInput,
                              snapshotBuilder: GoalEvaluationSnapshotBuilder,
                              in viewContext: NSManagedObjectContext) -> PreparedFacts {
        guard let goal = Self.fetchGoal(id: input.goalID, in: viewContext),
              let baseRow = GoalPlanRevisionStore.revisionRow(id: input.draft.baseRevisionID, in: viewContext),
              let payload = baseRow.planPayloadV2 else {
            return PreparedFacts(freshDigest: nil, currentFunds: nil)
        }
        let resolved = GoalResolvedPlan(revisionID: baseRow.id, revisionNumber: Int(baseRow.revisionNumber),
                                        payload: payload, didCreateBaseline: false)
        var digest: String?
        if let reportMessageID = input.draft.sourceReportMessageID,
           let link = GoalReviewCoordinator.link(reportMessageID: reportMessageID, in: viewContext) {
            let frozenWindow = GoalObservationWindow(
                start: link.windowStart, endExclusive: link.windowEndExclusive,
                cutoff: link.snapshotCutoffAt,
                timeZone: TimeZone(identifier: link.timeZoneID) ?? .current
            )
            digest = snapshotBuilder.build(goal: goal, plan: resolved, window: frozenWindow, now: link.snapshotCutoffAt).sourceDigest
        }
        let window = GoalObservationWindow.trailingDays(
            payload.review?.observationWindowDays ?? GoalPlanReviewV2.defaultObservationWindowDays,
            cutoff: input.now
        )
        let current = snapshotBuilder.build(goal: goal, plan: resolved, window: window, now: input.now)
        return PreparedFacts(freshDigest: digest, currentFunds: current.result.moneyValue)
    }

    nonisolated static func postSaveSideEffects(receipt: GoalAdjustmentCommitReceipt) async {
        await MainActor.run {
            TodoRepository.shared.loadActiveTasks()
            HabitRepository.shared.loadActiveHabits()
            GoalRepository.shared.loadGoals()
            GoalNotificationService.broadcastGoalDataChange()
            NotificationCenter.default.post(name: .habitDataDidChange, object: nil)
            NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            NotificationCenter.default.post(name: GoalReviewCoordinator.reviewStateDidChange, object: receipt.goalID)
        }
    }

    // MARK: - 单事务核心（隔离 context；只写，不读 MainActor 服务）

    static func performCommit(
        input: GoalAdjustmentCommitInput,
        facts: PreparedFacts,
        in context: NSManagedObjectContext
    ) throws -> GoalAdjustmentCommitReceipt {
        let draft = input.draft
        let now = input.now

        // 1) 目标与基础版本重读（后台 context 权威读取）
        guard let goal = fetchGoal(id: draft.goalID, in: context) else { throw GoalAdjustmentCommitError.goalMissing }
        guard let baseRow = GoalPlanRevisionStore.revisionRow(id: draft.baseRevisionID, in: context) else {
            throw GoalAdjustmentCommitError.baseRevisionChanged(
                currentRevisionID: GoalPlanRevisionStore.latestRevisionRow(goalID: draft.goalID, in: context)?.id ?? draft.baseRevisionID)
        }
        guard var payload = baseRow.planPayloadV2 else {
            throw GoalAdjustmentCommitError.validation(String(localized: "基础计划版本无法读取（可能来自更新版本），不能应用修改"))
        }

        // 2) 幂等（后台再核一次）+ 并发分支 + 基础版本仍为最新
        if let existing = GoalPlanRevisionStore.revisionRow(operationID: draft.draftID, goalID: draft.goalID, in: context) {
            return GoalAdjustmentCommitReceipt(goalID: draft.goalID, revisionID: existing.id,
                                               revisionNumber: Int(existing.revisionNumber),
                                               appliedOperationIDs: [], changedObjectTitles: [],
                                               wasIdempotentReplay: true)
        }
        let siblings = GoalPlanRevisionStore.childRevisionRows(baseRevisionID: baseRow.id, goalID: draft.goalID, in: context)
        if siblings.count > 1 {
            throw GoalAdjustmentCommitError.concurrentBranchDetected(siblingRevisionIDs: siblings.map(\.id))
        }
        if let latest = GoalPlanRevisionStore.latestRevisionRow(goalID: draft.goalID, in: context), latest.id != baseRow.id {
            throw GoalAdjustmentCommitError.baseRevisionChanged(currentRevisionID: latest.id)
        }

        // 3) 草案过期与依据变化
        if draft.isExpired(at: now) { throw GoalAdjustmentCommitError.draftExpired(expiresAt: draft.expiresAt) }
        if let freshDigest = facts.freshDigest, freshDigest != draft.sourceDigest {
            throw GoalAdjustmentCommitError.sourceDigestChanged
        }

        // 4) 原意保护
        let selectedOps = draft.selectedOperations
        if selectedOps.contains(where: { op in
            op.kind == .changeSuccessCriteria || (op.kind == .updateHabit && payload.bindings.contains { $0.entityID == op.targetEntityID && $0.role == .result })
        }) && !input.criteriaChangeConfirmed {
            throw GoalAdjustmentCommitError.separateConfirmationRequired
        }

        // 5) 确定性重算：资金期次按提交时点的当前资金重算每期应存（R26/R27）
        var recomputedPerInstallment: Decimal?
        var recomputedScheduleByOpID: [String: [GoalFundInstallmentV2]] = [:]
        if let scheduleOp = selectedOps.first(where: { $0.kind == .updateFundSchedule }),
           let schedule = scheduleOp.fundSchedule {
            let criteriaTarget = selectedOps
                .first { $0.kind == .changeSuccessCriteria }?.criteriaChange?.newTargetValue
            let target = criteriaTarget ?? payload.resultSource?.targetValue
            if let target {
                let outcome = GoalFundScheduleMath.evaluate(target: Decimal(target),
                                                            currentFunds: facts.currentFunds ?? 0,
                                                            schedule: schedule,
                                                            cutoff: now,
                                                            deadline: payload.intent.deadline)
                if let perInstallment = outcome.suggestedPerInstallment, !outcome.remainingInstallments.isEmpty {
                    recomputedPerInstallment = perInstallment
                    recomputedScheduleByOpID[scheduleOp.id] = outcome.remainingInstallments.map {
                        GoalFundInstallmentV2(dueDate: $0.dueDate, amount: perInstallment, note: $0.note)
                    }
                }
            }
        }

        // 6) 逐项应用（只构造不保存；任何一步失败抛错，context 由调用方丢弃）
        var appliedIDs: [String] = []
        var changedTitles: [String] = []
        var effectiveSchedule: [GoalFundInstallmentV2]?
        for op in selectedOps {
            try op.validateShape()
            try apply(op, to: &payload, goal: goal,
                      recomputedSchedule: recomputedScheduleByOpID[op.id],
                      now: now, in: context)
            appliedIDs.append(op.id)
            if let title = op.affectedObjectTitle ?? op.proposedSummary { changedTitles.append(title) }
            if op.kind == .updateFundSchedule {
                effectiveSchedule = recomputedScheduleByOpID[op.id] ?? op.fundSchedule
            }
        }
        if let schedule = effectiveSchedule {
            payload.fundSchedule = schedule.sorted { $0.dueDate < $1.dueDate }
        }

        // 7) 成果标准变更同步 Goal 当前量化配置（展示兼容）与 intent
        if let criteria = selectedOps.first(where: { $0.kind == .changeSuccessCriteria })?.criteriaChange {
            applyCriteriaChange(criteria, to: &payload, goal: goal)
        }
        payload.basis = GoalPlanDecisionBasisV2(
            origin: .adjustment,
            sourceSessionID: payload.basis.sourceSessionID,
            sourceReportMessageID: draft.sourceReportMessageID,
            confirmedAt: now,
            selectedChangeSummaries: selectedOps.compactMap { $0.proposedSummary ?? $0.affectedObjectTitle }
        )

        let nextNumber = Int(baseRow.revisionNumber) + 1
        let legacySummary = GoalWorkshopDecisionSummaryV1(
            definition: nil,
            selectedRouteTitle: nil,
            planTitle: goal.title,
            successEvidence: payload.intent.successCriteria ?? "",
            assumptions: [],
            firstActionTitle: nil,
            selectedTaskTitles: [],
            selectedHabitNames: [],
            allowAIContext: goal.allowAIContext,
            confirmedAt: now
        )
        let revisionRow = try GoalPlanRevisionStore.makeRevisionRow(
            in: context,
            goalID: goal.id,
            sourceSessionID: baseRow.sourceSessionID == GoalWorkshopSchemaDefaults.zeroUUID ? nil : baseRow.sourceSessionID,
            revisionNumber: nextNumber,
            baseRevisionID: baseRow.id,
            operationID: draft.draftID,
            effectiveFrom: now,
            payload: payload,
            legacySummary: legacySummary
        )

        try context.save()
        return GoalAdjustmentCommitReceipt(
            goalID: goal.id,
            revisionID: revisionRow.id,
            revisionNumber: nextNumber,
            appliedOperationIDs: appliedIDs,
            changedObjectTitles: changedTitles,
            wasIdempotentReplay: false,
            recomputedPerInstallment: recomputedPerInstallment
        )
    }

    // MARK: - 逐项应用

    private static func apply(_ op: GoalAdjustmentOperationV2,
                              to payload: inout GoalPlanPayloadV2,
                              goal: Goal,
                              recomputedSchedule: [GoalFundInstallmentV2]?,
                              now: Date,
                              in context: NSManagedObjectContext) throws {
        switch op.kind {
        case .createTask:
            let spec = try require(op.taskSpec, op)
            let task = TodoTask.create(in: context, title: spec.title, desc: spec.note,
                                       dueDate: spec.dueDate, isAllDay: true,
                                       plannedStart: spec.plannedStart, plannedEnd: spec.plannedEnd)
            task.goal = goal
            payload.bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .task, entityID: task.id),
                entityType: .task, entityID: task.id, draftRef: op.draftRef, role: .action,
                effectiveFrom: now, effectiveThrough: op.appliesThrough, displayTitle: task.title, isGoalOwned: true))

        case .reuseTask:
            let taskID = try require(op.targetEntityID, op)
            guard let task = fetchTask(id: taskID, in: context) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要关联的任务不存在"))
            }
            upsertBinding(&payload, GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .task, entityID: task.id),
                entityType: .task, entityID: task.id, draftRef: nil, role: .action,
                effectiveFrom: now, effectiveThrough: op.appliesThrough, displayTitle: task.title,
                isGoalOwned: task.goal?.id == goal.id))

        case .updateTask:
            let taskID = try require(op.targetEntityID, op)
            let spec = try require(op.taskSpec, op)
            guard let task = fetchTask(id: taskID, in: context) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要调整的任务不存在"))
            }
            if let title = spec.title.nilIfBlank { task.title = title }
            task.dueDate = spec.dueDate
            task.plannedStart = spec.plannedStart
            task.plannedEnd = spec.plannedEnd
            task.updatedAt = now
            touchBinding(&payload, entityType: .task, entityID: task.id) { $0.displayTitle = task.title }

        case .createHabit:
            let spec = try require(op.habitSpec, op)
            let habit = GoalRepository.makeHabit(
                from: GoalHabitDraft(id: op.draftRef ?? op.id, isSelected: true, name: spec.name,
                                     frequency: spec.frequency, targetCount: spec.targetCount,
                                     type: spec.type, unit: spec.unit, targetValue: spec.targetValue,
                                     isBadHabit: spec.isBadHabit, successRule: nil,
                                     aggregation: spec.aggregation.map { $0.rawValue }),
                goal: goal, in: context)
            payload.bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                entityType: .habit, entityID: habit.id, draftRef: op.draftRef, role: .action,
                effectiveFrom: now, effectiveThrough: op.appliesThrough, displayTitle: habit.name, isGoalOwned: true))

        case .reuseHabit:
            let habitID = try require(op.targetEntityID, op)
            guard let habit = fetchHabit(id: habitID, in: context) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要关联的习惯不存在"))
            }
            upsertBinding(&payload, GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                entityType: .habit, entityID: habit.id, draftRef: nil, role: op.role ?? .action,
                effectiveFrom: now, effectiveThrough: op.appliesThrough, displayTitle: habit.name,
                isGoalOwned: habit.goal?.id == goal.id))

        case .updateHabit:
            let habitID = try require(op.targetEntityID, op)
            let spec = try require(op.habitSpec, op)
            guard let habit = fetchHabit(id: habitID, in: context) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要调整的习惯不存在"))
            }
            guard spec.name.nilIfBlank == nil || spec.name == habit.name, spec.unit == nil || spec.unit == habit.unit else {
                throw GoalAdjustmentCommitError.validation("不能改名或改变行为含义，请结束旧绑定并关联替代习惯")
            }
            let cap = payload.constraints.first { rule in payload.bindings.contains { $0.id == rule.bindingID && $0.entityID == habit.id } }
            let prior = payload.bindings.first { $0.entityID == habit.id && $0.isActive }?.requirement
            let metric: GoalRequirementMetric = prior?.metric ?? (habit.isCheckInType ? (cap == nil ? .recordedDays : .eventCount) : habit.isMeasureType ? .latest : .sum)
            let role = payload.bindings.first { $0.entityID == habit.id && $0.isActive }?.role ?? op.role
            let comparison = prior?.comparison ?? (cap != nil || role == .constraint || spec.constraintLimit != nil ? .stayBelow : .reach)
            let target = spec.constraintLimit ?? spec.targetValue ?? spec.targetCount.map(Double.init) ?? prior?.target ?? cap?.limitValue
                ?? (habit.isCheckInType ? Double(truncating: habit.targetCount ?? 1) : habit.targetValue?.doubleValue)
            guard spec.type == (habit.isCheckInType ? "checkIn" : "numeric"),
                  spec.isBadHabit == nil || spec.isBadHabit == habit.isBadHabit,
                  HabitFrequency(rawValue: spec.frequency) != nil else {
                throw GoalAdjustmentCommitError.validation("不能改变共享习惯的记录方式或行为含义，请关联替代习惯")
            }
            guard let target, target.isFinite, target >= 0, target > 0 || comparison == .stayBelow else { throw GoalAdjustmentCommitError.validation("请明确本目标的要求") }
            if !payload.bindings.contains(where: { $0.entityType == .habit && $0.entityID == habit.id && $0.isActive }) {
                upsertBinding(&payload, GoalPlanBindingV2(id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                    entityType: .habit, entityID: habit.id, role: op.role ?? .action, displayTitle: habit.name, isGoalOwned: false))
            }
            touchBinding(&payload, entityType: .habit, entityID: habit.id) {
                $0.displayTitle = habit.name
                $0.requirement = GoalBindingRequirement(metric: metric, target: target, comparison: comparison,
                    windowDays: spec.constraintWindowDays ?? (spec.frequency == "monthly" ? 30 : spec.frequency == "weekly" ? 7 : 1),
                    calendarMonth: spec.frequency == "monthly")
            }
            if let cap { payload.constraints.removeAll { $0.bindingID == cap.bindingID } }
            payload.schemaVersion = 3

        case .createBudget:
            let rule = try require(op.budgetRule, op)
            guard let period = BudgetPeriod(rawValue: rule.period) else {
                throw GoalAdjustmentCommitError.validation(String(localized: "预算周期无效"))
            }
            if fetchBudget(accountID: rule.accountID, categoryID: rule.categoryID, period: rule.period, in: context) != nil {
                throw GoalAdjustmentCommitError.budgetConflict
            }
            let budget = Budget.create(in: context, accountId: rule.accountID,
                                       amount: NSDecimalNumber(decimal: rule.amount), period: period,
                                       startDate: max(rule.startDate, now), categoryId: rule.categoryID)
            payload.bindings.append(GoalPlanBindingV2(
                id: rule.bindingID, entityType: .budget, entityID: budget.id, draftRef: nil,
                role: .constraint, effectiveFrom: now, effectiveThrough: op.appliesThrough,
                displayTitle: op.affectedObjectTitle, isGoalOwned: true))
            payload.budgetRule = rule

        case .updateBudget:
            let rule = try require(op.budgetRule, op)
            guard let budgetID = rule.reuseExistingBudgetID ?? op.targetEntityID,
                  let budget = fetchBudget(id: budgetID, in: context) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要调整的预算不存在"))
            }
            // 预算是财务全局约定：只调金额，不改范围与周期；历史支出不回改（§3.4）
            budget.amount = NSDecimalNumber(decimal: rule.amount)
            budget.updatedAt = now
            var updated = rule
            updated.accountID = budget.accountId
            updated.categoryID = budget.categoryId
            updated.period = budget.period
            updated.startDate = budget.startDate
            updated.reuseExistingBudgetID = budget.id
            payload.budgetRule = updated
            touchBinding(&payload, entityType: .budget, entityID: budget.id) { $0.entityID = budget.id }

        case .endBinding:
            let bindingID = try require(op.targetBindingID, op)
            guard let index = payload.bindings.firstIndex(where: { $0.id == bindingID }) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要结束的安排不在当前计划里"))
            }
            // 阶段结束只结束本目标的绑定与临时要求，不删对象、不删记录（R31）
            payload.bindings[index].endedAt = now
            payload.constraints.removeAll { $0.bindingID == bindingID }

        case .replaceBinding:
            let bindingID = try require(op.targetBindingID, op)
            guard let index = payload.bindings.firstIndex(where: { $0.id == bindingID }) else {
                throw GoalAdjustmentCommitError.objectMissing(String(localized: "要替换的安排不在当前计划里"))
            }
            payload.bindings[index].endedAt = now
            payload.constraints.removeAll { $0.bindingID == bindingID }
            // 替代对象走同一条 create/reuse 路径；行为含义改变不继承旧次数（§4.3：口语练习不得靠改听读的名字继承）
            var replaceOp = op
            if op.habitSpec != nil, op.draftRef != nil {
                replaceOp.kind = .createHabit
            } else if op.targetEntityID != nil, op.habitSpec == nil, op.taskSpec == nil {
                replaceOp.kind = .reuseHabit
            } else {
                replaceOp.kind = .createTask
            }
            try apply(replaceOp, to: &payload, goal: goal, recomputedSchedule: nil, now: now, in: context)

        case .updateFundSchedule:
            // 期次金额已按提交时点重算（recomputedSchedule 优先）；schedule 本体在步骤 6 末统一写回 payload
            if recomputedSchedule == nil {
                _ = try require(op.fundSchedule, op)
            }

        case .updateReview:
            payload.review = try require(op.review, op)

        case .changeSuccessCriteria:
            // 字段同步在步骤 7 统一处理（需要 payload 全量语境）
            break
        }
    }

    private static func applyCriteriaChange(_ change: GoalAdjustmentCriteriaChangeV2,
                                            to payload: inout GoalPlanPayloadV2,
                                            goal: Goal) {
        if let raw = change.newSuccessCriteria, let criteria = raw.nilIfBlank {
            payload.intent.successCriteria = criteria
        }
        if let newDeadline = change.newDeadline {
            payload.intent.deadline = newDeadline
            goal.deadline = newDeadline
        }
        if var source = payload.resultSource, let newTarget = change.newTargetValue {
            source.targetValue = newTarget
            payload.resultSource = source
            goal.metricTargetValueDouble = newTarget
        }
        goal.updatedAt = Date()
    }

    // MARK: - 绑定辅助

    private static func upsertBinding(_ payload: inout GoalPlanPayloadV2, _ binding: GoalPlanBindingV2) {
        if let index = payload.bindings.firstIndex(where: {
            $0.id == binding.id || ($0.entityID == binding.entityID && $0.entityType == binding.entityType)
        }) {
            var merged = payload.bindings[index]
            merged.endedAt = nil
            merged.effectiveFrom = binding.effectiveFrom
            if binding.effectiveThrough != nil { merged.effectiveThrough = binding.effectiveThrough }
            merged.isGoalOwned = merged.isGoalOwned || binding.isGoalOwned
            if merged.role != .result { merged.role = binding.role }
            payload.bindings[index] = merged
        } else {
            payload.bindings.append(binding)
        }
    }

    private static func touchBinding(_ payload: inout GoalPlanPayloadV2,
                                     entityType: GoalPlanBindingEntityType,
                                     entityID: UUID,
                                     mutate: (inout GoalPlanBindingV2) -> Void) {
        let match: (GoalPlanBindingV2) -> Bool = { $0.entityType == entityType && $0.entityID == entityID }
        if let index = payload.bindings.firstIndex(where: { match($0) && $0.isActive }) {
            mutate(&payload.bindings[index])
        } else if let index = payload.bindings.firstIndex(where: match) {
            mutate(&payload.bindings[index])
        } else {
            var binding = GoalPlanBindingV2(id: GoalPlanBindingV2.stableID(entityType: entityType, entityID: entityID),
                                            entityType: entityType, entityID: entityID, draftRef: nil, role: .action,
                                            effectiveFrom: Date(), effectiveThrough: nil, displayTitle: nil, isGoalOwned: false)
            mutate(&binding)
            payload.bindings.append(binding)
        }
    }

    // MARK: - 取数

    private static func require<T>(_ value: T?, _ op: GoalAdjustmentOperationV2) throws -> T {
        guard let value else {
            throw GoalAdjustmentCommitError.validation(String(localized: "操作 \(op.id) 缺少必要参数"))
        }
        return value
    }

    static func fetchGoal(id: UUID, in context: NSManagedObjectContext) -> Goal? {
        let request = NSFetchRequest<Goal>(entityName: "Goal")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchTask(id: UUID, in context: NSManagedObjectContext) -> TodoTask? {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND archived == NO", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchHabit(id: UUID, in context: NSManagedObjectContext) -> Habit? {
        let request = NSFetchRequest<Habit>(entityName: "Habit")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchBudget(id: UUID, in context: NSManagedObjectContext) -> Budget? {
        let request = NSFetchRequest<Budget>(entityName: "Budget")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchBudget(accountID: UUID, categoryID: UUID?, period: String, in context: NSManagedObjectContext) -> Budget? {
        let request = NSFetchRequest<Budget>(entityName: "Budget")
        if let categoryID {
            request.predicate = NSPredicate(format: "accountId == %@ AND period == %@ AND categoryId == %@ AND deletedAt == nil",
                                            accountID as CVarArg, period, categoryID as CVarArg)
        } else {
            request.predicate = NSPredicate(format: "accountId == %@ AND period == %@ AND categoryId == nil AND deletedAt == nil",
                                            accountID as CVarArg, period)
        }
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
