//
//  GoalEvaluationSnapshotBuilder.swift
//  Holo
//
//  目标闭环·统一事实快照构建（最终规格 §6.2 / §6.3）
//
//  确定性规则全部在此由代码决定：时间窗口 [start, min(endExclusive, cutoff))、
//  结果状态、执行统计、限制判断、资金期次演算、依据摘要。模型只解释，不重算。
//
//  财务读取复用 FinanceRepository / BudgetRepository 现有口径，不另写收支计算器；
//  习惯窗口记录复用 HabitRepository.records(for:from:through:)（尊重习惯结算时间归属）。
//

import Foundation
import CoreData
import CryptoKit

@MainActor
final class GoalEvaluationSnapshotBuilder {

    private let context: NSManagedObjectContext
    private let financeRepository: FinanceRepository
    private let budgetRepository: BudgetRepository
    private let habitRepository: HabitRepository
    private let calendar: Calendar

    init(context: NSManagedObjectContext,
         financeRepository: FinanceRepository,
         budgetRepository: BudgetRepository,
         habitRepository: HabitRepository,
         calendar: Calendar = .current) {
        self.context = context
        self.financeRepository = financeRepository
        self.budgetRepository = budgetRepository
        self.habitRepository = habitRepository
        self.calendar = calendar
    }

    static func makeDefault() -> GoalEvaluationSnapshotBuilder {
        GoalEvaluationSnapshotBuilder(
            context: CoreDataStack.shared.viewContext,
            financeRepository: FinanceRepository.shared,
            budgetRepository: BudgetRepository.shared,
            habitRepository: HabitRepository.shared
        )
    }

    // MARK: - 入口

    func build(goal: Goal,
               plan: GoalResolvedPlan,
               window: GoalObservationWindow,
               now: Date = Date()) -> GoalEvaluationSnapshot {
        let payload = plan.payload
        let resolvedBindings = GoalPlanResolver.resolveBindings(goal: goal, payload: payload, at: window.cutoff)

        var known: [String] = []
        var unknown: [String] = []

        let result = buildResult(goal: goal, payload: payload, window: window, known: &known, unknown: &unknown)
        let execution = buildExecution(bindings: resolvedBindings, window: window, known: &known, unknown: &unknown)
        let constraints = buildConstraints(payload: payload, window: window, known: &known, unknown: &unknown)
        let review = buildReview(goalID: goal.id, payload: payload, now: now)
        let fundPlan = buildFundPlan(payload: payload, result: result, window: window, unknown: &unknown)

        var snapshot = GoalEvaluationSnapshot(
            goalID: goal.id,
            goalTitle: goal.title,
            planRevisionID: plan.revisionID,
            planRevisionNumber: plan.revisionNumber,
            generatedAt: now,
            windowStart: window.start,
            windowEndExclusive: window.endExclusive,
            snapshotCutoffAt: window.cutoff,
            timeZoneID: window.timeZone.identifier,
            successCriteria: payload.intent.successCriteria,
            deadline: payload.intent.deadline ?? goal.deadline,
            result: result,
            execution: execution,
            constraints: constraints,
            coverage: GoalCoverageFacts(known: known, unknown: unknown),
            review: review,
            fundPlan: fundPlan,
            sourceDigest: ""
        )
        snapshot.requirements = payload.activeBindings(at: window.cutoff).compactMap { binding in
            do { return try GoalRequirementEvaluator.evaluate(binding: binding, repository: habitRepository, context: context, cutoff: window.cutoff, calendar: calendar) }
            catch {
                snapshot.coverage.unknown.append("每日确认暂时无法读取，请重试")
                guard let rule = binding.requirement else { return nil }
                return GoalRequirementObservation(id: binding.id, title: binding.displayTitle ?? "目标条件",
                    entityID: binding.entityID, entityType: binding.entityType, role: binding.role,
                    requirement: rule, value: nil, unit: "", windowStart: window.start,
                    windowEndExclusive: window.endExclusive, confirmedDays: 0, expectedDays: rule.windowDays,
                    state: .unavailable, sourceDigest: "unavailable")
            }
        }
        snapshot.sourceDigest = Self.sourceDigest(for: snapshot)
        return snapshot
    }

    // MARK: - 结果

    private func buildResult(goal: Goal,
                             payload: GoalPlanPayloadV2,
                             window: GoalObservationWindow,
                             known: inout [String],
                             unknown: inout [String]) -> GoalResultObservation {
        guard let source = payload.resultSource else {
            return GoalResultObservation(status: .notApplicable,
                                         sourceKind: nil,
                                         sourceLabel: String(localized: "过程型目标"),
                                         note: String(localized: "没有结果量，只看执行情况"))
        }
        if source.isPending {
            unknown.append(String(localized: "结果来源待补齐"))
            return GoalResultObservation(status: .pendingSource,
                                         sourceKind: source.sourceType,
                                         sourceLabel: String(localized: "结果来源待补齐"),
                                         unit: source.unit,
                                         targetValue: source.targetValue,
                                         baselineValue: source.baselineValue,
                                         baselineObservedAt: source.baselineObservedAt)
        }

        switch source.sourceType {
        case .manual:
            return manualResult(goal: goal, source: source, window: window, known: &known, unknown: &unknown)
        case .habit:
            return habitResult(source: source, window: window, known: &known, unknown: &unknown)
        case .ledger:
            return ledgerResult(goal: goal, source: source, window: window, known: &known, unknown: &unknown)
        }
    }

    private func manualResult(goal: Goal,
                              source: GoalPlanResultSourceV2,
                              window: GoalObservationWindow,
                              known: inout [String],
                              unknown: inout [String]) -> GoalResultObservation {
        let request = GoalMetricLog.fetchRequest()
        let since = source.baselineObservedAt ?? goal.createdAt
        request.predicate = NSPredicate(
            format: "goalId == %@ AND deletedAt == nil AND date < %@",
            goal.id as CVarArg, window.cutoff as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false), NSSortDescriptor(key: "createdAt", ascending: false)]
        let logs = DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
        let label = String(localized: "手动记录")
        guard let latest = logs.first else {
            unknown.append(String(localized: "结果尚无手动记录"))
            return GoalResultObservation(status: .missing, sourceKind: .manual, sourceLabel: label,
                                         unit: source.unit, targetValue: source.targetValue,
                                         baselineValue: source.baselineValue, baselineObservedAt: source.baselineObservedAt)
        }
        let value: Double
        switch source.aggregation ?? .sum {
        case .sum:
            value = logs.filter { $0.date >= since }.reduce(0) { $0 + $1.value }
        case .latest, .windowTrend:
            value = latest.value
        }
        var observation = GoalResultObservation(status: .observed, sourceKind: .manual, sourceLabel: label,
                                                value: value, unit: source.unit, observedAt: latest.date,
                                                targetValue: source.targetValue, baselineValue: source.baselineValue,
                                                baselineObservedAt: source.baselineObservedAt)
        applyStaleness(&observation, source: source, cutoff: window.cutoff)
        observation.progressFraction = Self.progressFraction(value: value, source: source)
        known.append(String(localized: "结果最近记录于 \(Self.dayText(latest.date))"))
        return observation
    }

    private func habitResult(source: GoalPlanResultSourceV2,
                             window: GoalObservationWindow,
                             known: inout [String],
                             unknown: inout [String]) -> GoalResultObservation {
        guard let habitID = source.sourceID, let habit = fetchHabit(id: habitID) else {
            unknown.append(String(localized: "结果来源习惯不可用"))
            return GoalResultObservation(status: .unavailable, sourceKind: .habit,
                                         sourceLabel: String(localized: "结果习惯"),
                                         unit: source.unit, targetValue: source.targetValue,
                                         baselineValue: source.baselineValue, baselineObservedAt: source.baselineObservedAt,
                                         unavailableReason: String(localized: "习惯已删除或不存在，请重新选择来源"))
        }
        let label = habit.name
        let unit = source.unit ?? habit.unit
        if habit.isArchived {
            unknown.append(String(localized: "「\(label)」已归档"))
            return GoalResultObservation(status: .unavailable, sourceKind: .habit, sourceLabel: label, unit: unit,
                                         targetValue: source.targetValue, baselineValue: source.baselineValue,
                                         baselineObservedAt: source.baselineObservedAt,
                                         unavailableReason: String(localized: "习惯已归档"))
        }

        switch source.aggregation ?? .latest {
        case .latest, .windowTrend:
            // 体重等观测值：取 cutoff 前最新一条有值记录；按计划聚合语义读取，不受习惯自身 sum/latest 影响
            guard let record = latestValuedRecord(habitID: habit.id, before: window.cutoff) else {
                unknown.append(String(localized: "「\(label)」尚无观测"))
                return GoalResultObservation(status: .missing, sourceKind: .habit, sourceLabel: label, unit: unit,
                                             targetValue: source.targetValue, baselineValue: source.baselineValue,
                                             baselineObservedAt: source.baselineObservedAt)
            }
            var observation = GoalResultObservation(status: .observed, sourceKind: .habit, sourceLabel: label,
                                                    value: record.value, unit: unit, observedAt: record.date,
                                                    targetValue: source.targetValue, baselineValue: source.baselineValue,
                                                    baselineObservedAt: source.baselineObservedAt)
            applyStaleness(&observation, source: source, cutoff: window.cutoff)
            observation.progressFraction = Self.progressFraction(value: record.value, source: source)
            known.append(String(localized: "「\(label)」最新观测 \(Self.dayText(record.date))"))
            return observation
        case .sum:
            let records = windowRecords(habit: habit, window: window)
            let valued = records.compactMap { $0.valueDouble }.filter(\.isFinite)
            guard !records.isEmpty else {
                unknown.append(String(localized: "「\(label)」本窗口无记录"))
                return GoalResultObservation(status: .missing, sourceKind: .habit, sourceLabel: label, unit: unit,
                                             targetValue: source.targetValue, baselineValue: source.baselineValue,
                                             baselineObservedAt: source.baselineObservedAt)
            }
            let sum = valued.reduce(0, +)
            let latestAt = records.map(\.date).max()
            var observation = GoalResultObservation(status: .observed, sourceKind: .habit, sourceLabel: label,
                                                    value: sum, unit: unit, observedAt: latestAt,
                                                    targetValue: source.targetValue, baselineValue: source.baselineValue,
                                                    baselineObservedAt: source.baselineObservedAt)
            observation.progressFraction = Self.progressFraction(value: sum, source: source)
            known.append(String(localized: "「\(label)」窗口累计 \(records.count) 条记录"))
            return observation
        }
    }

    private func ledgerResult(goal: Goal,
                              source: GoalPlanResultSourceV2,
                              window: GoalObservationWindow,
                              known: inout [String],
                              unknown: inout [String]) -> GoalResultObservation {
        switch source.resolvedLedgerScope {
        case .wholeLedgerDelta:
            let since = source.baselineObservedAt ?? goal.createdAt
            let delta = financeRepository.getCumulativeBalance(before: window.cutoff)
                - financeRepository.getCumulativeBalance(before: since)
            let label = GoalLedgerScopeKind.wholeLedgerDelta.displayName
            var observation = GoalResultObservation(status: .observed, sourceKind: .ledger, sourceLabel: label,
                                                    moneyValue: delta, unit: source.unit ?? "元",
                                                    observedAt: window.cutoff,
                                                    targetValue: source.targetValue, baselineValue: source.baselineValue,
                                                    baselineObservedAt: since,
                                                    note: String(localized: "按全账本收支净额计算，不是专项旅行资金"))
            observation.progressFraction = Self.progressFraction(value: NSDecimalNumber(decimal: delta).doubleValue, source: source)
            known.append(String(localized: "全账本净结余自 \(Self.dayText(since)) 起的变化"))
            return observation
        case .accountBalance:
            guard let accountID = source.ledgerScope?.accountID else {
                unknown.append(String(localized: "尚未选定资金账户"))
                return GoalResultObservation(status: .pendingSource, sourceKind: .ledger,
                                             sourceLabel: GoalLedgerScopeKind.accountBalance.displayName,
                                             unit: source.unit ?? "元", targetValue: source.targetValue)
            }
            switch financeRepository.accountBalanceObservation(accountId: accountID, before: window.cutoff) {
            case .observed(let balance, let asOf, let accountName, let accountType):
                let label = String(localized: "账户「\(accountName)」余额")
                var observation = GoalResultObservation(status: .observed, sourceKind: .ledger, sourceLabel: label,
                                                        moneyValue: balance, unit: source.unit ?? "元",
                                                        observedAt: asOf,
                                                        targetValue: source.targetValue, baselineValue: source.baselineValue,
                                                        baselineObservedAt: source.baselineObservedAt)
                if accountType == .creditCard {
                    observation.note = String(localized: "信用账户余额不代表可用资金")
                }
                observation.progressFraction = Self.progressFraction(value: NSDecimalNumber(decimal: balance).doubleValue, source: source)
                known.append(String(localized: "账户「\(accountName)」余额截至 \(Self.dayText(asOf))"))
                return observation
            case .accountMissing:
                unknown.append(String(localized: "资金账户不存在"))
                return GoalResultObservation(status: .unavailable, sourceKind: .ledger,
                                             sourceLabel: GoalLedgerScopeKind.accountBalance.displayName,
                                             unit: source.unit ?? "元", targetValue: source.targetValue,
                                             unavailableReason: String(localized: "账户不存在，请重新选择来源"))
            case .accountDeleted:
                unknown.append(String(localized: "资金账户已删除"))
                return GoalResultObservation(status: .unavailable, sourceKind: .ledger,
                                             sourceLabel: GoalLedgerScopeKind.accountBalance.displayName,
                                             unit: source.unit ?? "元", targetValue: source.targetValue,
                                             unavailableReason: String(localized: "账户已删除，请重新选择来源"))
            case .queryFailed:
                unknown.append(String(localized: "资金账户查询失败"))
                return GoalResultObservation(status: .unavailable, sourceKind: .ledger,
                                             sourceLabel: GoalLedgerScopeKind.accountBalance.displayName,
                                             unit: source.unit ?? "元", targetValue: source.targetValue,
                                             unavailableReason: String(localized: "余额查询失败，稍后重试"))
            }
        }
    }

    private func applyStaleness(_ observation: inout GoalResultObservation,
                                source: GoalPlanResultSourceV2,
                                cutoff: Date) {
        guard let freshnessDays = source.freshnessDays, freshnessDays > 0,
              let observedAt = observation.observedAt,
              let threshold = calendar.date(byAdding: .day, value: -freshnessDays, to: cutoff),
              observedAt < threshold else { return }
        observation.status = .stale
        observation.note = String(localized: "最近观测已超过 \(freshnessDays) 天")
    }

    /// 结果进度：reach/sum 用 value/target；trendDown 用 (baseline-value)/(baseline-target)；无意义时 nil
    static func progressFraction(value: Double, source: GoalPlanResultSourceV2) -> Double? {
        guard let target = source.targetValue else { return nil }
        switch source.comparison ?? .reach {
        case .reach:
            guard target > 0 else { return nil }
            return min(max(value / target, 0), 1)
        case .trendDown:
            guard let baseline = source.baselineValue, baseline > target else { return nil }
            return min(max((baseline - value) / (baseline - target), 0), 1)
        case .trendUp:
            guard let baseline = source.baselineValue, target > baseline else { return nil }
            return min(max((value - baseline) / (target - baseline), 0), 1)
        case .stayBelow:
            return nil
        }
    }

    // MARK: - 执行

    private func buildExecution(bindings: [GoalResolvedBinding],
                                window: GoalObservationWindow,
                                known: inout [String],
                                unknown: inout [String]) -> [GoalExecutionItem] {
        var items: [GoalExecutionItem] = []
        for resolved in bindings {
            let binding = resolved.binding
            switch binding.entityType {
            case .task:
                items.append(taskItem(binding: binding, owned: resolved.isOwnedByGoalRelationship, window: window))
            case .habit:
                items.append(habitItem(binding: binding, owned: resolved.isOwnedByGoalRelationship, window: window))
            case .budget, .account, .fundSchedule:
                continue
            }
        }
        let tasks = items.filter { $0.entityType == .task && !$0.isUnavailable }
        if !tasks.isEmpty {
            known.append(String(localized: "任务完成 \(tasks.filter { $0.taskCompleted == true }.count)/\(tasks.count)"))
        }
        let habits = items.filter { $0.entityType == .habit && !$0.isUnavailable }
        if !habits.isEmpty {
            known.append(String(localized: "\(habits.count) 个习惯的窗口记录"))
        }
        for item in items where item.isUnavailable {
            unknown.append(String(localized: "「\(item.title)」不可用"))
        }
        return items
    }

    private func taskItem(binding: GoalPlanBindingV2, owned: Bool, window: GoalObservationWindow) -> GoalExecutionItem {
        var item = GoalExecutionItem(id: binding.id, entityType: .task, entityID: binding.entityID,
                                     title: binding.displayTitle ?? String(localized: "任务"),
                                     role: binding.role, isOwnedByGoal: owned, isUnavailable: false)
        guard let taskID = binding.entityID, let task = fetchTask(id: taskID) else {
            item.isUnavailable = true
            item.unavailableReason = String(localized: "任务已删除")
            return item
        }
        item.title = task.title
        item.taskCompleted = task.completed
        item.taskCompletedAt = task.completedAt
        item.taskDueDate = task.dueDate
        item.taskPlannedStart = task.plannedStart
        if let due = task.dueDate {
            item.taskIsOverdue = !task.completed && due < window.cutoff
        } else {
            item.taskIsOverdue = false
        }
        if let completedAt = task.completedAt {
            item.taskCompletedInWindow = window.contains(completedAt)
        } else {
            item.taskCompletedInWindow = false
        }
        return item
    }

    private func habitItem(binding: GoalPlanBindingV2, owned: Bool, window: GoalObservationWindow) -> GoalExecutionItem {
        var item = GoalExecutionItem(id: binding.id, entityType: .habit, entityID: binding.entityID,
                                     title: binding.displayTitle ?? String(localized: "习惯"),
                                     role: binding.role, isOwnedByGoal: owned, isUnavailable: false)
        guard let habitID = binding.entityID, let habit = fetchHabit(id: habitID) else {
            item.isUnavailable = true
            item.unavailableReason = String(localized: "习惯已删除")
            return item
        }
        item.title = habit.name
        item.habitAggregation = habit.isMeasureType ? "latest" : "sum"
        item.habitFrequency = habit.frequency
        item.habitIsPaused = habit.isPaused
        item.habitUnit = habit.unit
        if habit.isArchived {
            item.isUnavailable = true
            item.unavailableReason = String(localized: "习惯已归档")
            return item
        }
        let records = windowRecords(habit: habit, window: window)
        let dayEnd = habit.dayEndMinutes
        let eligibleRecords = habit.isCheckInType ? records.filter(\.isCompleted) : records
        let recordedDays = Set(eligibleRecords.map { $0.attributedDay(dayEndMinutes: dayEnd, calendar: calendar) }).count
        let expected = expectedDays(habit: habit, window: window)
        item.habitRecordedDays = recordedDays
        item.habitExpectedDays = expected
        item.habitCompletionRate = expected > 0 ? min(Double(recordedDays) / Double(expected), 1) : nil
        if habit.isNumericType {
            let valued = records.compactMap(\.valueDouble).filter(\.isFinite)
            item.habitWindowSum = valued.isEmpty ? nil : valued.reduce(0, +)
            if let latest = latestValuedRecord(habitID: habit.id, before: window.cutoff) {
                item.habitLatestValue = latest.value
                item.habitLatestValueAt = latest.date
            }
        }
        return item
    }

    /// 期望记录天数：daily=窗口天数；weekly=周数×targetCount；monthly=月数×targetCount
    private func expectedDays(habit: Habit, window: GoalObservationWindow) -> Int {
        let days = windowDayCount(window)
        guard days > 0 else { return 0 }
        let target = max(Int(truncating: habit.targetCount ?? 1), 1)
        switch habit.habitFrequency {
        case .daily:
            return days
        case .weekly:
            return max(Int((Double(days) / 7.0).rounded(.up)), 1) * target
        case .monthly:
            return max(Int((Double(days) / 30.0).rounded(.up)), 1) * target
        }
    }

    // MARK: - 限制

    private func buildConstraints(payload: GoalPlanPayloadV2,
                                  window: GoalObservationWindow,
                                  known: inout [String],
                                  unknown: inout [String]) -> [GoalConstraintStatus] {
        var statuses: [GoalConstraintStatus] = []

        for rule in payload.constraints {
            guard let binding = payload.binding(id: rule.bindingID), binding.isEffective(at: window.cutoff) else { continue }
            let title = rule.displayTitle ?? binding.displayTitle ?? String(localized: "限制")
            let limitWindow = GoalObservationWindow.trailingDays(rule.windowDays, cutoff: window.cutoff, timeZone: window.timeZone)
            let windowLabel = String(localized: "最近 \(rule.windowDays) 天")
            var status = GoalConstraintStatus(id: rule.bindingID, kind: .habitLimit, title: title,
                                              limitValue: Decimal(rule.limitValue), unit: rule.unit,
                                              windowLabel: windowLabel,
                                              windowStart: limitWindow.start, windowEndExclusive: limitWindow.effectiveEndExclusive,
                                              hasRecords: false, isUnavailable: false)
            guard let habitID = rule.habitID ?? binding.entityID, let habit = fetchHabit(id: habitID), !habit.isArchived else {
                status.isUnavailable = true
                status.note = String(localized: "限制对应的习惯不可用")
                unknown.append(String(localized: "「\(title)」对应习惯不可用"))
                statuses.append(status)
                continue
            }
            // 阶段规则只解释生效后的记录（§6.2）
            var effectiveWindow = limitWindow
            if let from = binding.effectiveFrom, from > effectiveWindow.start {
                effectiveWindow.start = from
            }
            let records = windowRecords(habit: habit, window: effectiveWindow)
            status.hasRecords = !records.isEmpty
            var confirmed = 0, expected = 0, confirmationParts: [String] = []
            var day = calendar.startOfDay(for: max(effectiveWindow.start, habit.createdAt))
            while day < effectiveWindow.effectiveEndExclusive {
                if !habit.isDayPaused(day, calendar: calendar) {
                    expected += 1
                    do {
                        if let fact = try habitRepository.dailyConfirmation(for: habit, on: day), fact.isValid {
                            confirmationParts.append("\(day)|\(fact.status.rawValue)")
                            if fact.status != .asOf { confirmed += 1 }
                        }
                    } catch { unknown.append("每日确认读取失败，不能判断上限") }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }; day = next
            }
            status.confirmedDays = confirmed; status.expectedDays = expected
            status.confirmationDigest = confirmationParts.joined(separator: "|")
            let total = habit.isNumericType ? records.compactMap(\.valueDouble).filter(\.isFinite).reduce(0, +) : Double(records.filter(\.isCompleted).count)
            if !records.isEmpty || confirmed > 0 {
                status.observedValue = Decimal(total)
                status.isBreached = total > rule.limitValue ? true : nil
                status.note = "已记录量；\(confirmed)/\(expected) 天确认，当前周期仍在进行"
                known.append("「\(title)」已记录 \(total)，\(confirmed) 天明确确认")
            } else {
                status.isBreached = nil; status.note = "尚无记录，不能当作真实零"
                unknown.append("「\(title)」尚无记录")
            }
            statuses.append(status)
        }

        if let rule = payload.budgetRule,
           let binding = payload.binding(id: rule.bindingID),
           binding.isEffective(at: window.cutoff) {
            let title = binding.displayTitle ?? String(localized: "预算")
            var status = GoalConstraintStatus(id: rule.bindingID, kind: .budget, title: title,
                                              limitValue: rule.amount, unit: "元",
                                              windowLabel: BudgetPeriod(rawValue: rule.period)?.displayName ?? rule.period,
                                              hasRecords: false, isUnavailable: false)
            if let budget = fetchBudget(rule: rule), let computed = budgetRepository.computeBudgetStatus(budget: budget) {
                status.limitValue = computed.effectiveAmount
                status.observedValue = computed.spentAmount
                status.windowStart = computed.periodStartDate
                status.windowEndExclusive = computed.periodEndDate
                status.hasRecords = true
                status.isBreached = computed.isOverBudget
                known.append(String(localized: "预算「\(title)」本期已花 \(Self.moneyText(computed.spentAmount))"))
            } else {
                status.isUnavailable = true
                status.note = String(localized: "预算不存在或已删除")
                unknown.append(String(localized: "预算「\(title)」不可用"))
            }
            statuses.append(status)
        }
        return statuses
    }

    // MARK: - 回顾

    private func buildReview(goalID: UUID, payload: GoalPlanPayloadV2, now: Date) -> GoalReviewStatus {
        let review = payload.review
        let request = NSFetchRequest<GoalReviewLinkMO>(entityName: "GoalReviewLinkMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND statusRaw == %@ AND deletedAt == nil",
            goalID as CVarArg, GoalReviewLinkStatus.completed.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
        request.fetchLimit = 1
        let last = (try? context.fetch(request))?.first
        // 到期判定：有过完成的回顾 → 上次完成 + 周期；没有 → 计划里的首个 nextReviewAt。
        // 关闭定期回顾（cadence nil）永不到期；完成回顾不改写计划 payload。
        var isDue = false
        var nextReviewAt = review?.nextReviewAt
        if let cadence = review?.cadenceDays, cadence > 0 {
            if let completedAt = last?.completedAt,
               let next = calendar.date(byAdding: .day, value: cadence, to: completedAt) {
                nextReviewAt = next
                isDue = next <= now
            } else if let next = review?.nextReviewAt {
                isDue = next <= now
            }
        }
        return GoalReviewStatus(cadenceDays: review?.cadenceDays,
                                nextReviewAt: nextReviewAt,
                                isDue: isDue,
                                lastCompletedReviewAt: last?.completedAt,
                                lastReportMessageID: last?.reportMessageID)
    }

    // MARK: - 资金期次

    private func buildFundPlan(payload: GoalPlanPayloadV2,
                               result: GoalResultObservation,
                               window: GoalObservationWindow,
                               unknown: inout [String]) -> GoalFundPlanStatus? {
        guard let source = payload.resultSource, source.sourceType == .ledger,
              !payload.fundSchedule.isEmpty,
              let targetDouble = source.targetValue else { return nil }
        let target = Decimal(targetDouble)
        let pastCount = payload.fundSchedule.filter { $0.dueDate < window.cutoff }.count
        var status = GoalFundPlanStatus(target: target,
                                        currentFunds: result.moneyValue,
                                        installmentsTotal: payload.fundSchedule.count,
                                        installmentsPast: pastCount,
                                        outcome: nil)
        guard result.status == .observed, let current = result.moneyValue else {
            unknown.append(String(localized: "资金现状未知，无法演算剩余期次"))
            return status
        }
        status.outcome = GoalFundScheduleMath.evaluate(target: target,
                                                       currentFunds: current,
                                                       schedule: payload.fundSchedule,
                                                       cutoff: window.cutoff,
                                                       deadline: payload.intent.deadline)
        return status
    }

    // MARK: - 依据摘要

    /// 只摘与判断相关的数据：结果观测、执行、限制、资金现状、计划版本；不含 generatedAt
    static func sourceDigest(for snapshot: GoalEvaluationSnapshot) -> String {
        var lines: [String] = []
        lines.append("plan:\(snapshot.planRevisionID.uuidString)")
        let r = snapshot.result
        lines.append("result:\(r.status.rawValue)|\(r.value.map { String($0) } ?? "-")|\(r.moneyValue.map { "\($0)" } ?? "-")|\(r.observedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-")")
        for item in snapshot.execution.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("exec:\(item.id.uuidString)|\(item.isUnavailable)|\(item.taskCompleted.map(String.init) ?? "-")|\(item.habitRecordedDays.map(String.init) ?? "-")|\(item.habitWindowSum.map { String($0) } ?? "-")|\(item.habitLatestValue.map { String($0) } ?? "-")")
        }
        for c in snapshot.constraints.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("confirmation:\(c.confirmationDigest ?? "-")")
            lines.append("constraint:\(c.id.uuidString)|\(c.hasRecords)|\(c.observedValue.map { "\($0)" } ?? "-")|\(c.isBreached.map(String.init) ?? "-")|\(c.isUnavailable)")
        }
        for item in (snapshot.requirements ?? []).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("requirement:\(item.id)|\(item.value.map(String.init(describing:)) ?? "-")|\(item.state.rawValue)|\(item.sourceDigest)")
        }
        if let fund = snapshot.fundPlan {
            lines.append("fund:\(fund.currentFunds.map { "\($0)" } ?? "-")|\(fund.installmentsPast)/\(fund.installmentsTotal)")
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: - 取数

    private func fetchTask(id: UUID) -> TodoTask? {
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func fetchHabit(id: UUID) -> Habit? {
        let request = NSFetchRequest<Habit>(entityName: "Habit")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func fetchBudget(rule: GoalBudgetRuleV2) -> Budget? {
        let request = NSFetchRequest<Budget>(entityName: "Budget")
        if let budgetID = rule.reuseExistingBudgetID {
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", budgetID as CVarArg)
        } else if let categoryID = rule.categoryID {
            request.predicate = NSPredicate(
                format: "accountId == %@ AND period == %@ AND categoryId == %@ AND deletedAt == nil",
                rule.accountID as CVarArg, rule.period, categoryID as CVarArg
            )
        } else {
            request.predicate = NSPredicate(
                format: "accountId == %@ AND period == %@ AND categoryId == nil AND deletedAt == nil",
                rule.accountID as CVarArg, rule.period
            )
        }
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 窗口内归属记录：日归属交给习惯模块（尊重结算时间），再剔除 cutoff 之后的记录
    private func windowRecords(habit: Habit, window: GoalObservationWindow) -> [HabitRecord] {
        let lastDay = calendar.startOfDay(for: window.effectiveEndExclusive.addingTimeInterval(-1))
        guard lastDay >= calendar.startOfDay(for: window.start) else { return [] }
        return habitRepository.records(for: habit, from: window.start, through: lastDay)
            .filter { $0.date < window.cutoff }
    }

    private struct ValuedRecord { let value: Double; let date: Date }

    private func latestValuedRecord(habitID: UUID, before cutoff: Date) -> ValuedRecord? {
        let request = HabitRecord.fetchRequest()
        request.predicate = NSPredicate(
            format: "habitId == %@ AND value != nil AND date < %@ AND deletedAt == nil",
            habitID as CVarArg, cutoff as NSDate
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "date", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        request.fetchLimit = 1
        guard let row = (try? context.fetch(request))?.first, let value = row.valueDouble, value.isFinite else { return nil }
        return ValuedRecord(value: value, date: row.date)
    }

    private func windowDayCount(_ window: GoalObservationWindow) -> Int {
        let start = calendar.startOfDay(for: window.start)
        let endDay = calendar.startOfDay(for: window.effectiveEndExclusive.addingTimeInterval(-1))
        let days = (calendar.dateComponents([.day], from: start, to: endDay).day ?? 0) + 1
        return max(days, 0)
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    static func moneyText(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "zh_CN")
        return (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)") + " 元"
    }
}

/// GoalReviewLinkMO.statusRaw 取值
enum GoalReviewLinkStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    /// 报告仍可读，但依据/计划已变化，建议待刷新
    case stale
    /// 报告消息已删除，关联不可用
    case unavailable
}
