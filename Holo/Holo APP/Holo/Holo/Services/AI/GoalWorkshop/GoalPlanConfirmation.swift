//
//  GoalPlanConfirmation.swift
//  Holo
//
//  目标闭环·确认页最终确认的计划扩展（最终规格 §3.1）
//
//  GoalDraft 之外、用户在确认页「结果 / 执行安排 / 可选限制 / 回顾」四区确认的部分：
//  结果来源（授权 ID）、回顾节奏、可选预算、资金期次、行为限制。
//  共创、旧规划、手动创建三个入口都经由它进入同一提交器，不保留绕过来源/版本验证的支路。
//

import Foundation

struct GoalBudgetConfirmation: Equatable, Identifiable {
    var id: UUID
    var isSelected: Bool
    var title: String
    var accountID: UUID?
    var categoryID: UUID?
    var amount: Decimal
    /// BudgetPeriod.rawValue
    var period: String
    var startDate: Date
    /// 同范围同周期已有预算：用户选择复用（非 nil）或修改既有（由 D 阶段处理）；新建为 nil
    var reuseExistingBudgetID: UUID?

    var isReady: Bool { accountID != nil && amount > 0 }
}

struct GoalConstraintConfirmation: Equatable, Identifiable {
    /// 即 bindingID
    var id: UUID
    var isSelected: Bool
    var title: String
    /// 二选一：本草案新建习惯 id（提交时解析）或既有习惯 id
    var habitDraftID: String?
    var habitID: UUID?
    var limitValue: Double
    var unit: String?
    var windowDays: Int
    /// 阶段性要求的结束日；nil = 跟随目标
    var effectiveThrough: Date?
}

struct GoalPlanConfirmation: Equatable {
    var originalWish: String?
    var successCriteria: String
    var resultSource: GoalPlanResultSourceV2?
    /// 结果来源指向本草案内新建的数值习惯时，提交时解析成真实 id
    var resultSourceHabitDraftID: String?
    var review: GoalPlanReviewV2
    var budget: GoalBudgetConfirmation?
    var fundSchedule: [GoalFundInstallmentV2]
    var constraints: [GoalConstraintConfirmation]

    /// 旧手建 / 旧 AI 规划草案：从草案量化字段推导来源，默认每周回顾，无预算/期次/限制
    static func defaults(from draft: GoalDraft, successEvidence: String, now: Date) -> GoalPlanConfirmation {
        var source: GoalPlanResultSourceV2?
        if draft.isQuantitative {
            let aggregation: GoalHabitAggregationKind = draft.goalKind == .cumulative ? .sum : .latest
            let kind: GoalResultSourceKind
            switch draft.metricSource {
            case .manual: kind = .manual
            case .habit: kind = .habit
            case .ledger: kind = .ledger
            }
            let comparison: GoalResultComparison
            if draft.goalKind == .target, let target = draft.metricTargetValue, let baseline = draft.metricBaselineValue, target < baseline {
                comparison = .trendDown
            } else {
                comparison = .reach
            }
            source = GoalPlanResultSourceV2(
                sourceType: kind,
                sourceID: kind == .habit ? draft.sourceHabitId : nil,
                unit: draft.metricUnit,
                aggregation: aggregation,
                comparison: comparison,
                targetValue: draft.metricTargetValue,
                baselineValue: draft.goalKind == .target ? draft.metricBaselineValue : nil,
                baselineObservedAt: now,
                freshnessDays: aggregation == .latest ? 14 : nil,
                ledgerScope: nil,
                isPending: kind == .habit && draft.sourceHabitId == nil
            )
        }
        return GoalPlanConfirmation(
            originalWish: draft.desiredOutcome,
            successCriteria: successEvidence.isEmpty ? (draft.desiredOutcome ?? draft.title) : successEvidence,
            resultSource: source,
            resultSourceHabitDraftID: nil,
            review: GoalPlanReviewV2.weeklyDefault(now: now),
            budget: nil,
            fundSchedule: [],
            constraints: []
        )
    }

    /// 共创草案 → 确认页初始状态：模型建议映射成授权 ID 与可编辑项；用户可逐项取消/编辑
    static func from(plan: GoalWorkshopPlan,
                     candidates: GoalWorkshopAuthorizedCandidates,
                     now: Date,
                     calendar: Calendar = .current) -> GoalPlanConfirmation {
        var confirmation = defaults(from: plan.draft, successEvidence: plan.successEvidence, now: now)
        confirmation.originalWish = plan.draft.desiredOutcome ?? plan.draft.summary

        if let source = plan.resultSource, let kind = GoalResultSourceKind(rawValue: source.sourceType) {
            var sourceID: UUID?
            var pending = source.isPending ?? false
            var ledgerScope: GoalLedgerScopePayload?
            switch kind {
            case .habit:
                if let ref = source.candidateRef, let candidate = candidates.habit(ref: ref) {
                    sourceID = candidate.id
                } else if source.habitDraftID == nil {
                    pending = true
                }
            case .ledger:
                let scopeKind = source.ledgerScope.flatMap(GoalLedgerScopeKind.init(rawValue:)) ?? .wholeLedgerDelta
                if scopeKind == .accountBalance {
                    if let ref = source.candidateRef, let account = candidates.account(ref: ref), !account.isCreditLiability {
                        ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)
                    } else {
                        // 没有可靠账户：范围保留 account_balance 待用户选定，结果待补齐
                        ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: nil)
                        pending = true
                    }
                } else {
                    ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
                }
            case .manual:
                break
            }
            let aggregation = source.aggregation.flatMap(GoalHabitAggregationKind.init(rawValue:))
                ?? (kind == .ledger ? .sum : .latest)
            confirmation.resultSource = GoalPlanResultSourceV2(
                sourceType: kind,
                sourceID: sourceID,
                unit: source.unit ?? plan.draft.metricUnit,
                aggregation: aggregation,
                comparison: source.comparison.flatMap(GoalResultComparison.init(rawValue:)) ?? .reach,
                targetValue: source.targetValue ?? plan.draft.metricTargetValue,
                baselineValue: source.baselineValue,
                baselineObservedAt: now,
                freshnessDays: aggregation == .latest ? 14 : nil,
                ledgerScope: ledgerScope,
                isPending: pending
            )
            confirmation.resultSourceHabitDraftID = kind == .habit ? source.habitDraftID : nil
        }

        var review = GoalPlanReviewV2.weeklyDefault(now: now, calendar: calendar)
        if let cadence = plan.reviewCadenceDays {
            review.cadenceDays = cadence
            review.nextReviewAt = calendar.date(byAdding: .day, value: cadence, to: now)
        }
        if let reviewDate = plan.reviewDateText, let date = GoalWorkshopValidator.strictDayFormatter.date(from: reviewDate) {
            review.nextReviewAt = date
        }
        confirmation.review = review

        if let budget = plan.budget, let period = BudgetPeriod(rawValue: budget.period) {
            let account = budget.accountCandidateRef.flatMap(candidates.account(ref:))
            confirmation.budget = GoalBudgetConfirmation(
                id: UUID(),
                isSelected: budget.isSelected,
                title: budget.categoryName.map { "\($0)预算" } ?? String(localized: "预算"),
                accountID: account?.id,
                categoryID: nil,
                amount: Decimal(budget.amount),
                period: period.rawValue,
                startDate: calendar.startOfDay(for: now),
                reuseExistingBudgetID: nil
            )
        }

        confirmation.fundSchedule = (plan.fundSchedule ?? []).compactMap { installment in
            guard let date = GoalWorkshopValidator.strictDayFormatter.date(from: installment.dueDateText) else { return nil }
            return GoalFundInstallmentV2(dueDate: date, amount: Decimal(installment.amount), note: nil)
        }

        confirmation.constraints = (plan.constraints ?? []).map { constraint in
            GoalConstraintConfirmation(
                id: UUID(),
                isSelected: constraint.isSelected,
                title: constraint.title,
                habitDraftID: constraint.habitDraftID,
                habitID: constraint.habitCandidateRef.flatMap(candidates.habit(ref:))?.id,
                limitValue: constraint.limitValue,
                unit: constraint.unit,
                windowDays: constraint.windowDays,
                effectiveThrough: nil
            )
        }
        return confirmation
    }
}
