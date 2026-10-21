//
//  GoalPlanResolver.swift
//  Holo
//
//  目标闭环·生效计划解析（最终规格 §6.1）
//
//  - 取目标当前生效计划（最新 v2 版本）；旧目标/手动目标/仅 v1 摘要的目标，
//    首次接入时从当前真实字段与关联生成 legacy 基线版本（标明来源），不改原目标与原模块对象。
//  - 已有 v2 版本直接复用；多次进入不重复创建。
//  - 未来 schema 抛错，由调用方提示只读，不能当空计划覆盖。
//  - 统一绑定解析：Goal.tasks / Goal.habits 单父关系（专属对象）与计划逻辑绑定（共享对象）
//    合并去重，所有目标读取与跳转只走这里，不让报告认识共享对象而详情页看不见。
//

import Foundation
import CoreData

struct GoalResolvedPlan: Equatable {
    let revisionID: UUID
    let revisionNumber: Int
    let payload: GoalPlanPayloadV2
    /// 本次解析是否刚创建了 legacy 基线（调用方据此决定是否刷新）
    let didCreateBaseline: Bool
}

enum GoalPlanResolveError: Error, Equatable {
    /// 版本由更新的客户端写入：只读展示，禁止覆盖
    case unsupportedFutureSchema(version: Int)
    case corruptedPayload(revisionID: UUID)
    case goalDeleted
}

/// 统一绑定解析结果：一个真实对象只出现一次
struct GoalResolvedBinding: Equatable, Identifiable {
    let binding: GoalPlanBindingV2
    /// 对象是否由 Goal.tasks / Goal.habits 单父关系持有（专属）
    let isOwnedByGoalRelationship: Bool

    var id: UUID { binding.id }
}

enum GoalPlanResolver {

    // MARK: - 生效计划

    /// 解析生效计划；无 v2 版本时生成 legacy 基线。
    /// - Parameter persist: true 时在给定 context 上 save（独立读取场景）；
    ///   统一提交器内传 false，由提交器一次 save。
    static func resolveCurrentPlan(goal: Goal,
                                   now: Date = Date(),
                                   in context: NSManagedObjectContext,
                                   persist: Bool) throws -> GoalResolvedPlan {
        guard goal.deletedAt == nil else { throw GoalPlanResolveError.goalDeleted }
        let latest = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context)

        if let latest {
            switch latest.planPayloadDecodeResult {
            case .current(let payload):
                return GoalResolvedPlan(revisionID: latest.id,
                                        revisionNumber: Int(latest.revisionNumber),
                                        payload: payload,
                                        didCreateBaseline: false)
            case .unsupportedFuture(let version):
                throw GoalPlanResolveError.unsupportedFutureSchema(version: version)
            case .corrupted:
                throw GoalPlanResolveError.corruptedPayload(revisionID: latest.id)
            case .legacyDecisionSummary, .empty:
                break
            }
        }

        let legacySummary = try? latest?.decodeSummary()
        let payload = legacyBaselinePayload(goal: goal, legacySummary: legacySummary, now: now)
        let nextNumber = Int(latest?.revisionNumber ?? 0) + 1
        let row = try GoalPlanRevisionStore.makeRevisionRow(
            in: context,
            goalID: goal.id,
            sourceSessionID: goal.sourceSessionID,
            revisionNumber: nextNumber,
            baseRevisionID: latest?.id,
            operationID: nil,
            effectiveFrom: goal.createdAt,
            payload: payload,
            legacySummary: nil
        )
        if persist {
            try context.save()
        }
        return GoalResolvedPlan(revisionID: row.id,
                                revisionNumber: nextNumber,
                                payload: payload,
                                didCreateBaseline: true)
    }

    /// 从当前真实字段与关联生成 legacy 基线 payload（不写库、不改对象）
    static func legacyBaselinePayload(goal: Goal,
                                     legacySummary: GoalWorkshopDecisionSummaryV1?,
                                     now: Date) -> GoalPlanPayloadV2 {
        let successCriteria = legacySummary?.successEvidence.nilIfBlank
            ?? goal.desiredOutcome?.nilIfBlank
        let intent = GoalPlanIntentV2(originalWish: goal.summary?.nilIfBlank ?? goal.desiredOutcome?.nilIfBlank,
                                      successCriteria: successCriteria,
                                      deadline: goal.deadline)

        var bindings: [GoalPlanBindingV2] = []
        for task in goal.sortedTasks {
            bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .task, entityID: task.id),
                entityType: .task,
                entityID: task.id,
                draftRef: nil,
                role: .action,
                effectiveFrom: task.createdAt,
                effectiveThrough: nil,
                displayTitle: task.title,
                isGoalOwned: true
            ))
        }
        for habit in goal.sortedHabits {
            let isResultSource = goal.metricSourceEnum == .habit && goal.sourceHabitId == habit.id
            bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                entityType: .habit,
                entityID: habit.id,
                draftRef: nil,
                role: isResultSource ? .result : .action,
                effectiveFrom: habit.createdAt,
                effectiveThrough: nil,
                displayTitle: habit.name,
                isGoalOwned: true
            ))
        }
        // 结果来源习惯不是专属对象时（旧 sourceHabitId 指向共享习惯）：以逻辑绑定补上，不抢父引用
        if goal.metricSourceEnum == .habit,
           let sourceHabitId = goal.sourceHabitId,
           !bindings.contains(where: { $0.entityType == .habit && $0.entityID == sourceHabitId }) {
            bindings.append(GoalPlanBindingV2(
                id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: sourceHabitId),
                entityType: .habit,
                entityID: sourceHabitId,
                draftRef: nil,
                role: .result,
                effectiveFrom: goal.baselineDate ?? goal.createdAt,
                effectiveThrough: nil,
                displayTitle: nil,
                isGoalOwned: false
            ))
        }

        let origin: GoalPlanOrigin = goal.source == "manual" ? .manual : .legacy
        return GoalPlanPayloadV2(
            intent: intent,
            resultSource: legacyResultSource(goal: goal),
            bindings: bindings,
            fundSchedule: [],
            budgetRule: nil,
            constraints: [],
            review: GoalPlanReviewV2.weeklyDefault(now: now),
            basis: GoalPlanDecisionBasisV2(origin: origin,
                                           sourceSessionID: goal.sourceSessionID,
                                           sourceReportMessageID: nil,
                                           confirmedAt: now)
        )
    }

    /// 旧量化字段 → 结果来源；过程型目标无结果量（nil）。
    /// ledger 的 ledgerScope 保持 nil：按旧「全账本净结余增量」解释，不静默切账户余额（§6.2）
    static func legacyResultSource(goal: Goal) -> GoalPlanResultSourceV2? {
        guard goal.isQuantitative else { return nil }
        let isCumulative = goal.goalKindEnum == .cumulative
        let aggregation: GoalHabitAggregationKind = isCumulative ? .sum : .latest
        let sourceKind: GoalResultSourceKind
        var sourceID: UUID?
        switch goal.metricSourceEnum {
        case .manual:
            sourceKind = .manual
        case .habit:
            sourceKind = .habit
            sourceID = goal.sourceHabitId
        case .ledger:
            sourceKind = .ledger
        }
        return GoalPlanResultSourceV2(
            sourceType: sourceKind,
            sourceID: sourceID,
            unit: goal.metricUnit,
            aggregation: aggregation,
            comparison: legacyComparison(goal: goal),
            targetValue: goal.metricTargetValueDouble,
            baselineValue: goal.baselineValueDouble,
            baselineObservedAt: goal.baselineDate,
            freshnessDays: isCumulative ? nil : 14,
            ledgerScope: nil,
            isPending: sourceKind == .habit && sourceID == nil
        )
    }

    private static func legacyComparison(goal: Goal) -> GoalResultComparison {
        guard goal.goalKindEnum == .target,
              let target = goal.metricTargetValueDouble,
              let baseline = goal.baselineValueDouble else { return .reach }
        return target < baseline ? .trendDown : .reach
    }

    // MARK: - 统一绑定解析

    /// 合并计划逻辑绑定与 Goal.tasks / Goal.habits 单父关系，按真实对象去重。
    /// 计划内已有的绑定保持其 id/角色；仅由关系持有的对象补稳定 id 的 action 绑定。
    static func resolveBindings(goal: Goal, payload: GoalPlanPayloadV2, at date: Date) -> [GoalResolvedBinding] {
        let ownedTaskIDs = Set(goal.sortedTasks.map(\.id))
        let ownedHabitIDs = Set(goal.sortedHabits.map(\.id))

        var resolved: [GoalResolvedBinding] = []
        var seenEntities = Set<String>()

        for binding in payload.bindings where binding.isEffective(at: date) {
            if let entityID = binding.entityID {
                let key = "\(binding.entityType.rawValue)#\(entityID.uuidString)"
                guard seenEntities.insert(key).inserted else { continue }
                let owned = (binding.entityType == .task && ownedTaskIDs.contains(entityID))
                    || (binding.entityType == .habit && ownedHabitIDs.contains(entityID))
                resolved.append(GoalResolvedBinding(binding: binding, isOwnedByGoalRelationship: owned))
            } else {
                // 预算/资金期次等非对象绑定；或尚未解析的 draftRef
                resolved.append(GoalResolvedBinding(binding: binding, isOwnedByGoalRelationship: false))
            }
        }

        for task in goal.sortedTasks {
            let key = "task#\(task.id.uuidString)"
            guard seenEntities.insert(key).inserted else { continue }
            resolved.append(GoalResolvedBinding(
                binding: GoalPlanBindingV2(
                    id: GoalPlanBindingV2.stableID(entityType: .task, entityID: task.id),
                    entityType: .task,
                    entityID: task.id,
                    draftRef: nil,
                    role: .action,
                    effectiveFrom: task.createdAt,
                    effectiveThrough: nil,
                    displayTitle: task.title,
                    isGoalOwned: true
                ),
                isOwnedByGoalRelationship: true
            ))
        }
        for habit in goal.sortedHabits {
            let key = "habit#\(habit.id.uuidString)"
            guard seenEntities.insert(key).inserted else { continue }
            let isResultSource = payload.resultSource?.sourceType == .habit && payload.resultSource?.sourceID == habit.id
            resolved.append(GoalResolvedBinding(
                binding: GoalPlanBindingV2(
                    id: GoalPlanBindingV2.stableID(entityType: .habit, entityID: habit.id),
                    entityType: .habit,
                    entityID: habit.id,
                    draftRef: nil,
                    role: isResultSource ? .result : .action,
                    effectiveFrom: habit.createdAt,
                    effectiveThrough: nil,
                    displayTitle: habit.name,
                    isGoalOwned: true
                ),
                isOwnedByGoalRelationship: true
            ))
        }
        return resolved
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
