//
//  GoalWorkshopCommitService.swift
//  Holo
//
//  目标共创·原子提交（方案任务 6 / §2.4）
//
//  - 确认页保存 = 一次数据库事务：Goal + 关联任务/习惯 + 决策版本 + 会话回执，
//    只调用一次 context.save()；中途任何失败 rollback，不落半套数据。
//  - 幂等：同会话已提交（Goal.sourceSessionID 已存在）直接返回已有回执；
//    重复点击/重试/跨设备同逻辑 ID 均不重复创建。
//  - 通知/提醒/看板纳入/列表刷新只在保存成功后发生，不在构造过程中发。
//  - 旧手建与旧 AI 草案（GoalRepository.saveDraft）复用同一事务。
//

import Foundation
import CoreData

struct GoalWorkshopCommitReceipt: Equatable {
    let goalID: UUID
    let createdTaskCount: Int
    let createdHabitCount: Int
    let revisionNumber: Int
    /// 命中幂等（未创建新数据）时为 true
    let wasIdempotentReplay: Bool
    // 目标闭环 v2
    var revisionID: UUID? = nil
    var createdBudgetCount: Int = 0
    var reusedHabitCount: Int = 0
    /// 结果来源待补齐（用户需去原模块完善后再选）
    var resultSourcePending: Bool = false
}

struct GoalWorkshopCommitInput {
    let session: GoalWorkshopSessionV1
    /// 用户在确认页最终编辑后的草案
    let draft: GoalDraft
    let successEvidence: String
    let assumptions: [String]
    let allowAIContext: Bool
    /// 确认页「结果 / 回顾 / 预算 / 期次 / 限制」最终状态；nil = 按草案推导默认
    var confirmation: GoalPlanConfirmation? = nil
}

@MainActor
final class GoalWorkshopCommitService {

    static let shared = GoalWorkshopCommitService()

    private init() {}

    enum CommitError: Error, Equatable {
        case sessionAlreadyApplied(goalID: UUID)
        case validation(String)
        case saveFailed(String)
        /// 同范围同周期已有预算：须在确认页选择复用或修改，不静默新建第二份（R32）
        case budgetConflict
    }

    /// 会话确认：后台上下文单事务提交 + 保存成功后的统一副作用
    func commitWorkshop(_ input: GoalWorkshopCommitInput) async throws -> GoalWorkshopCommitReceipt {
        let context = CoreDataStack.shared.newBackgroundContext()
        let receipt = try await context.perform {
            try Self.performCommit(
                draft: input.draft,
                allowAIContext: input.allowAIContext,
                source: "goalWorkshop",
                sourceSessionID: input.session.id,
                successEvidence: input.successEvidence,
                assumptions: input.assumptions,
                selectedRouteTitle: input.session.routeOptions
                    .first { $0.id == input.session.selectedRouteID }?.title,
                confirmation: input.confirmation,
                in: context
            )
        }
        guard !receipt.wasIdempotentReplay else { return receipt }
        await Self.postSaveSideEffects(receipt: receipt)
        return receipt
    }

    /// 保存成功后的统一出口：刷新列表、发数据变更通知、习惯入看板。
    /// 各模块通知只在保存成功后发出（§2.4），失败路径不会到达这里。
    nonisolated static func postSaveSideEffects(receipt: GoalWorkshopCommitReceipt) async {
        await MainActor.run {
            TodoRepository.shared.loadActiveTasks()
            HabitRepository.shared.loadActiveHabits()
            GoalRepository.shared.loadGoals()
            GoalNotificationService.broadcastGoalDataChange()
            if receipt.createdBudgetCount > 0 {
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
            // 新习惯纳入看板（与 HabitRepository.createHabit 同口径）：按目标关联反查习惯 id
            let request = NSFetchRequest<Habit>(entityName: "Habit")
            request.predicate = NSPredicate(format: "goal.id == %@ AND deletedAt == nil", receipt.goalID as CVarArg)
            for habit in (try? CoreDataStack.shared.viewContext.fetch(request)) ?? [] {
                HabitStatsDisplaySettings.shared.addDashboardHabitIfNeeded(habit.id)
            }
        }
    }

    // MARK: - 单事务核心（同步、context 无关；saveDraft 与会话提交共用）

    /// 在给定 context 内构造 Goal/任务/习惯/预算/决策版本/会话回执并只保存一次。
    /// 任何一步失败抛错，context 由调用方 rollback/丢弃。
    /// - Parameter confirmation: 确认页最终状态；nil 时按草案推导（旧手建/旧规划入口）
    static func performCommit(
        draft: GoalDraft,
        allowAIContext: Bool,
        source: String,
        sourceSessionID: UUID?,
        successEvidence: String,
        assumptions: [String],
        selectedRouteTitle: String?,
        confirmation: GoalPlanConfirmation? = nil,
        now: Date = Date(),
        in context: NSManagedObjectContext
    ) throws -> GoalWorkshopCommitReceipt {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CommitError.validation("目标标题不能为空")
        }
        // 日期严格校验与响应契约同口径（确认页可能改动日期）
        var dateTexts: [String] = []
        if let deadline = draft.deadlineText { dateTexts.append(deadline) }
        for task in draft.tasks where task.isSelected {
            if let due = task.dueDateText { dateTexts.append(due) }
        }
        for text in dateTexts where !GoalWorkshopValidator.isValidStrictDay(text) {
            throw CommitError.validation("日期格式应为 yyyy-MM-dd：\(text)")
        }

        // 幂等：同会话已提交过 → 返回已有回执，不再创建
        if let sourceSessionID,
           let existing = fetchGoalIDBySessionID(sourceSessionID, in: context) {
            return GoalWorkshopCommitReceipt(
                goalID: existing,
                createdTaskCount: 0,
                createdHabitCount: 0,
                revisionNumber: 0,
                wasIdempotentReplay: true,
                revisionID: GoalPlanRevisionStore.latestRevisionRow(goalID: existing, in: context)?.id
            )
        }

        let plan = confirmation ?? GoalPlanConfirmation.defaults(from: draft, successEvidence: successEvidence, now: now)

        // 构造 Goal（不保存）
        let goal = Goal.create(
            in: context,
            title: trimmedTitle,
            summary: draft.summary,
            domain: draft.domain,
            desiredOutcome: draft.desiredOutcome,
            motivation: draft.motivation,
            deadline: Self.parseDay(draft.deadlineText),
            allowAIContext: allowAIContext
        )
        goal.iconEmoji = draft.iconEmoji
        goal.source = source
        goal.sourceSessionID = sourceSessionID
        Self.applyQuantitativeFields(from: draft, to: goal, now: now)

        var bindings: [GoalPlanBindingV2] = []
        /// 草案 id → 真实对象 id（结果来源 / 限制引用解析）
        var habitIDByDraftID: [String: UUID] = [:]

        // 构造任务（业务映射唯一真源在 GoalRepository 的无保存构造器）
        var taskCount = 0
        for (index, taskDraft) in draft.tasks.enumerated() where taskDraft.isSelected {
            #if DEBUG
            if GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex?(index) == true {
                throw CommitError.saveFailed("任务构造失败（测试注入）#\(index)")
            }
            #endif
            let task = GoalRepository.makeTask(from: taskDraft, goal: goal, in: context)
            taskCount += 1
            bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .task, entityID: task.id),
                entityType: .task, entityID: task.id, draftRef: taskDraft.id, role: .action,
                effectiveFrom: now, effectiveThrough: nil, displayTitle: task.title, isGoalOwned: true
            ))
        }

        // 构造 / 复用习惯：复用只建逻辑绑定，不抢对象原有 goal 父引用（§6.1 / R06）
        var habitCount = 0
        var reusedCount = 0
        for (index, habitDraft) in draft.habits.enumerated() where habitDraft.isSelected {
            #if DEBUG
            if GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex?(index) == true {
                throw CommitError.saveFailed("习惯构造失败（测试注入）#\(index)")
            }
            #endif
            if let reuseID = habitDraft.reuseHabitID {
                guard let existing = fetchHabit(id: reuseID, in: context) else {
                    throw CommitError.validation("要复用的习惯不存在：\(habitDraft.name)")
                }
                reusedCount += 1
                habitIDByDraftID[habitDraft.id] = existing.id
                bindings.append(GoalPlanBindingV2(
                    id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: existing.id),
                    entityType: .habit, entityID: existing.id, draftRef: habitDraft.id, role: .action,
                    effectiveFrom: now, effectiveThrough: nil, displayTitle: existing.name, isGoalOwned: false
                ))
            } else {
                let habit = GoalRepository.makeHabit(from: habitDraft, goal: goal, in: context)
                habitCount += 1
                habitIDByDraftID[habitDraft.id] = habit.id
                bindings.append(GoalPlanBindingV2(
                    id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                    entityType: .habit, entityID: habit.id, draftRef: habitDraft.id, role: .action,
                    effectiveFrom: now, effectiveThrough: nil, displayTitle: habit.name, isGoalOwned: true
                ))
            }
        }

        // 结果来源：解析草案内新建习惯；把生效来源同步到 Goal 当前量化配置（展示兼容）
        var resultSource = plan.resultSource
        if var source = resultSource {
            if source.sourceType == .habit, source.sourceID == nil,
               let draftID = plan.resultSourceHabitDraftID, let habitID = habitIDByDraftID[draftID] {
                source.sourceID = habitID
                source.isPending = false
            }
            if source.sourceType == .habit, let habitID = source.sourceID,
               let index = bindings.firstIndex(where: { $0.entityType == .habit && $0.entityID == habitID }) {
                bindings[index].role = .result
            } else if source.sourceType == .habit, let habitID = source.sourceID {
                // 结果来源指向未在行动里的既有习惯：补一条非专属 result 绑定
                guard fetchHabit(id: habitID, in: context) != nil else {
                    throw CommitError.validation("结果来源习惯不存在")
                }
                bindings.append(GoalPlanBindingV2(
                    id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habitID),
                    entityType: .habit, entityID: habitID, draftRef: nil, role: .result,
                    effectiveFrom: now, effectiveThrough: nil, displayTitle: nil, isGoalOwned: false
                ))
            }
            if source.sourceType == .ledger, source.resolvedLedgerScope == .accountBalance {
                if let accountID = source.ledgerScope?.accountID {
                    guard fetchAccount(id: accountID, in: context) != nil else {
                        throw CommitError.validation("资金账户不存在")
                    }
                    bindings.append(GoalPlanBindingV2(
                        id: GoalPlanBindingV2.stableID(entityType: .account, entityID: accountID),
                        entityType: .account, entityID: accountID, draftRef: nil, role: .result,
                        effectiveFrom: now, effectiveThrough: nil, displayTitle: nil, isGoalOwned: false
                    ))
                } else {
                    source.isPending = true
                }
            }
            if source.baselineObservedAt == nil { source.baselineObservedAt = now }
            resultSource = source
            Self.applyResultSource(source, to: goal)
        }

        // 预算（财务全局约定）：同范围同周期已有预算须明确复用或修改，不静默新建第二份（R32）
        var budgetRule: GoalBudgetRuleV2?
        var budgetCount = 0
        if let budgetConfirmation = plan.budget, budgetConfirmation.isSelected {
            guard let accountID = budgetConfirmation.accountID, budgetConfirmation.amount > 0 else {
                throw CommitError.validation("预算需要选定账户和金额")
            }
            guard let period = BudgetPeriod(rawValue: budgetConfirmation.period) else {
                throw CommitError.validation("预算周期无效")
            }
            let bindingID = budgetConfirmation.id
            if let reuseID = budgetConfirmation.reuseExistingBudgetID {
                guard let existing = fetchBudget(id: reuseID, in: context) else {
                    throw CommitError.validation("要复用的预算不存在")
                }
                budgetRule = GoalBudgetRuleV2(bindingID: bindingID, accountID: existing.accountId, categoryID: existing.categoryId,
                                              amount: existing.amount.decimalValue, period: existing.period,
                                              startDate: existing.startDate, reuseExistingBudgetID: existing.id)
                bindings.append(GoalPlanBindingV2(
                    id: bindingID, entityType: .budget, entityID: existing.id, draftRef: nil, role: .constraint,
                    effectiveFrom: now, effectiveThrough: nil, displayTitle: budgetConfirmation.title, isGoalOwned: false
                ))
            } else {
                if fetchBudget(accountID: accountID, categoryID: budgetConfirmation.categoryID, period: period.rawValue, in: context) != nil {
                    throw CommitError.budgetConflict
                }
                #if DEBUG
                if GoalWorkshopCommitHooks.shared.shouldFailBudget?() == true {
                    throw CommitError.saveFailed("预算构造失败（测试注入）")
                }
                #endif
                let budget = Budget.create(in: context, accountId: accountID,
                                           amount: NSDecimalNumber(decimal: budgetConfirmation.amount),
                                           period: period, startDate: budgetConfirmation.startDate,
                                           categoryId: budgetConfirmation.categoryID)
                budgetCount += 1
                budgetRule = GoalBudgetRuleV2(bindingID: bindingID, accountID: accountID, categoryID: budgetConfirmation.categoryID,
                                              amount: budgetConfirmation.amount, period: period.rawValue,
                                              startDate: budgetConfirmation.startDate, reuseExistingBudgetID: nil)
                bindings.append(GoalPlanBindingV2(
                    id: bindingID, entityType: .budget, entityID: budget.id, draftRef: nil, role: .constraint,
                    effectiveFrom: now, effectiveThrough: nil, displayTitle: budgetConfirmation.title, isGoalOwned: true
                ))
            }
        }

        // 行为限制：从原始数量另算；引用解析到真实习惯
        var constraints: [GoalConstraintRuleV2] = []
        for constraintConfirmation in plan.constraints where constraintConfirmation.isSelected {
            let habitID: UUID
            if let existingID = constraintConfirmation.habitID {
                habitID = existingID
            } else if let draftID = constraintConfirmation.habitDraftID, let created = habitIDByDraftID[draftID] {
                habitID = created
            } else {
                throw CommitError.validation("限制「\(constraintConfirmation.title)」没有对应的习惯")
            }
            guard fetchHabit(id: habitID, in: context) != nil else {
                throw CommitError.validation("限制对应的习惯不存在：\(constraintConfirmation.title)")
            }
            let isOwned = bindings.contains { $0.entityType == .habit && $0.entityID == habitID && $0.isGoalOwned }
            bindings.append(GoalPlanBindingV2(
                id: constraintConfirmation.id, entityType: .habit, entityID: habitID, draftRef: constraintConfirmation.habitDraftID,
                role: .constraint, effectiveFrom: now, effectiveThrough: constraintConfirmation.effectiveThrough,
                displayTitle: constraintConfirmation.title, isGoalOwned: isOwned
            ))
            constraints.append(GoalConstraintRuleV2(
                bindingID: constraintConfirmation.id, habitID: habitID, draftRef: constraintConfirmation.habitDraftID,
                limitValue: constraintConfirmation.limitValue, unit: constraintConfirmation.unit,
                windowDays: constraintConfirmation.windowDays, displayTitle: constraintConfirmation.title
            ))
        }

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(originalWish: plan.originalWish,
                                     successCriteria: plan.successCriteria,
                                     deadline: goal.deadline),
            resultSource: resultSource,
            bindings: bindings,
            fundSchedule: plan.fundSchedule.sorted { $0.dueDate < $1.dueDate },
            budgetRule: budgetRule,
            constraints: constraints,
            review: plan.review,
            basis: GoalPlanDecisionBasisV2(
                origin: Self.origin(for: source),
                sourceSessionID: sourceSessionID,
                sourceReportMessageID: nil,
                confirmedAt: now
            )
        )

        // 决策版本：新建目标首版恒为 1；operationID = 会话 id（重复点按/重试同键）
        let revisionNumber = 1
        let legacySummary = GoalWorkshopDecisionSummaryV1(
            definition: GoalWorkshopGoalDefinition(
                title: trimmedTitle,
                desiredOutcome: draft.desiredOutcome,
                motivation: draft.motivation,
                deadlineText: draft.deadlineText
            ),
            selectedRouteTitle: selectedRouteTitle,
            planTitle: trimmedTitle,
            successEvidence: plan.successCriteria,
            assumptions: assumptions,
            firstActionTitle: nil,
            selectedTaskTitles: draft.tasks.filter(\.isSelected).map(\.title),
            selectedHabitNames: draft.habits.filter(\.isSelected).map(\.name),
            allowAIContext: allowAIContext,
            confirmedAt: now
        )
        let revisionRow = try GoalPlanRevisionStore.makeRevisionRow(
            in: context,
            goalID: goal.id,
            sourceSessionID: sourceSessionID,
            revisionNumber: revisionNumber,
            baseRevisionID: nil,
            operationID: sourceSessionID ?? UUID(),
            effectiveFrom: now,
            payload: payload,
            legacySummary: sourceSessionID != nil ? legacySummary : nil
        )

        // 会话回执（同事务）
        if let sourceSessionID {
            Self.applySessionReceipt(sessionID: sourceSessionID, goalID: goal.id, in: context)
        }

        #if DEBUG
        if GoalWorkshopCommitHooks.shared.shouldFailSave?() == true {
            throw CommitError.saveFailed("context.save 失败（测试注入）")
        }
        #endif

        try context.save()
        return GoalWorkshopCommitReceipt(
            goalID: goal.id,
            createdTaskCount: taskCount,
            createdHabitCount: habitCount,
            revisionNumber: revisionNumber,
            wasIdempotentReplay: false,
            revisionID: revisionRow.id,
            createdBudgetCount: budgetCount,
            reusedHabitCount: reusedCount,
            resultSourcePending: resultSource?.isPending ?? false
        )
    }

    // MARK: - 私有

    static func fetchGoalIDBySessionID(_ sessionID: UUID, in context: NSManagedObjectContext) -> UUID? {
        let request = NSFetchRequest<Goal>(entityName: "Goal")
        request.predicate = NSPredicate(
            format: "sourceSessionID == %@ AND deletedAt == nil",
            sessionID as CVarArg
        )
        request.fetchLimit = 1
        // iCloud 副本天然同 id：取任一即可（同 sourceSessionID 即同一逻辑目标）
        return (try? context.fetch(request))?.first?.id
    }

    static func fetchHabit(id: UUID, in context: NSManagedObjectContext) -> Habit? {
        let request = NSFetchRequest<Habit>(entityName: "Habit")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchAccount(id: UUID, in context: NSManagedObjectContext) -> Account? {
        let request = NSFetchRequest<Account>(entityName: "Account")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    static func fetchBudget(id: UUID, in context: NSManagedObjectContext) -> Budget? {
        let request = NSFetchRequest<Budget>(entityName: "Budget")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 同范围（账户 + 分类）同周期的既有预算（R32 冲突检测）
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

    static func origin(for source: String) -> GoalPlanOrigin {
        switch source {
        case "goalWorkshop": return .workshop
        case "manual": return .manual
        default: return .planning
        }
    }

    /// 生效结果来源 → Goal 当前量化配置（列表/详情旧展示沿用；ledgerScope 从本期开始真实写入）
    static func applyResultSource(_ source: GoalPlanResultSourceV2, to goal: Goal) {
        goal.goalKindEnum = (source.aggregation ?? .sum) == .sum ? .cumulative : .target
        switch source.sourceType {
        case .manual: goal.metricSourceEnum = .manual
        case .habit: goal.metricSourceEnum = .habit
        case .ledger: goal.metricSourceEnum = .ledger
        }
        goal.metricUnit = source.unit
        goal.metricTargetValueDouble = source.targetValue
        goal.baselineValueDouble = goal.goalKindEnum == .target ? source.baselineValue : nil
        goal.sourceHabitId = source.sourceType == .habit ? source.sourceID : nil
        goal.ledgerScope = source.sourceType == .ledger ? source.resolvedLedgerScope.rawValue : nil
        goal.baselineDate = source.baselineObservedAt
    }

    static func applySessionReceipt(sessionID: UUID, goalID: UUID, in context: NSManagedObjectContext) {
        let request = NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")
        request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
        for row in (try? context.fetch(request)) ?? [] {
            row.appliedGoalID = goalID
            row.phase = .saved
            row.updatedAt = Date()
        }
    }

    /// 与旧链路一致的宽松日解析（yyyy-MM-dd）；响应侧严格校验已在上游完成
    static func parseDay(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return GoalWorkshopValidator.strictDayFormatter.date(from: text)
    }

    static func applyQuantitativeFields(from draft: GoalDraft, to goal: Goal, now: Date) {
        goal.goalKindEnum = draft.goalKind
        guard draft.isQuantitative else { return }
        goal.metricSourceEnum = draft.metricSource
        goal.metricUnit = draft.metricUnit
        goal.metricTargetValueDouble = draft.metricTargetValue
        goal.baselineValueDouble = draft.goalKind == .target ? draft.metricBaselineValue : nil
        goal.sourceHabitId = draft.metricSource == .habit ? draft.sourceHabitId : nil
        goal.baselineDate = now
    }
}

#if DEBUG
/// 失败注入钩子（仅测试使用；生产构建不存在）
final class GoalWorkshopCommitHooks {
    static let shared = GoalWorkshopCommitHooks()
    var shouldFailTaskAtIndex: ((Int) -> Bool)?
    var shouldFailHabitAtIndex: ((Int) -> Bool)?
    var shouldFailBudget: (() -> Bool)?
    var shouldFailSave: (() -> Bool)?
}
#endif
