import Foundation
import CoreData

/// 手动修改本目标约定也追加真实计划版本；不写共享习惯或预算。
@MainActor
enum GoalPlanEditService {
    static func message(for error: Error) -> String {
        if let value = error as? GoalPlanResolveError { return GoalReviewCoordinator.describe(value) }
        if let value = error as? GoalAdjustmentCommitError {
            switch value {
            case .validation(let text), .saveFailed(let text), .objectMissing(let text): return text
            case .separateConfirmationRequired: return "请单独确认这次目标约定的变化"
            case .baseRevisionChanged, .concurrentBranchDetected: return "计划已变化，请重新打开后核对"
            default: break
            }
        }
        return "暂时没有保存成功，原内容已保留，请重试"
    }
    static func save(goalID: UUID, baseRevisionID: UUID, payload: GoalPlanPayloadV2,
                     operationID: UUID, successChangeConfirmed: Bool, in contextOverride: NSManagedObjectContext? = nil) throws {
        let source = contextOverride ?? CoreDataStack.shared.viewContext
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = source.persistentStoreCoordinator
        if GoalPlanRevisionStore.revisionRow(operationID: operationID, goalID: goalID, in: context) != nil { return }
        let request = NSFetchRequest<Goal>(entityName: "Goal")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", goalID as CVarArg)
        guard let goal = try context.fetch(request).first,
              let base = GoalPlanRevisionStore.latestRevisionRow(goalID: goalID, in: context), base.id == baseRevisionID,
              let old = base.planPayloadV2 else { throw GoalAdjustmentCommitError.validation("计划已变化，请重新打开后核对") }
        guard successChangeConfirmed else { throw GoalAdjustmentCommitError.separateConfirmationRequired }
        for binding in payload.bindings {
            if let rule = binding.requirement {
                guard binding.entityType == .habit || binding.entityType == .task,
                      (binding.entityType == .task) == (rule.metric == .taskCompletion),
                      rule.metric != .taskCompletion || (rule.target == 1 && rule.comparison == .reach) else {
                    throw GoalAdjustmentCommitError.validation("任务条件按是否完成判断；习惯需选择有效的读取方式")
                }
                if binding.entityType == .habit, let id = binding.entityID {
                    let request = NSFetchRequest<Habit>(entityName: "Habit")
                    request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
                    if let habit = try context.fetch(request).first, habit.isCheckInType, [.sum, .latest].contains(rule.metric) {
                        throw GoalAdjustmentCommitError.validation("打卡型习惯请按完成天数或次数读取")
                    }
                }
                guard rule.target.isFinite, rule.target >= 0, rule.target > 0 || rule.comparison == .stayBelow,
                      (1...366).contains(rule.windowDays),
                      ![GoalRequirementMetric.recordedDays, .eventCount, .taskCompletion].contains(rule.metric) || rule.target.rounded() == rule.target,
                      rule.metric != .recordedDays || rule.target <= Double(rule.calendarMonth ? 31 : rule.windowDays) else { throw GoalAdjustmentCommitError.validation("请填写有效的要求与周期") }
            }
        }
        if let target = payload.resultSource?.targetValue, !target.isFinite || target <= 0 {
            throw GoalAdjustmentCommitError.validation("请填写大于零的成果目标值")
        }
        guard payload.fundSchedule.allSatisfy({ $0.amount >= 0 }) else {
            throw GoalAdjustmentCommitError.validation("计划存入金额不能小于零")
        }
        guard payload != old else { return }
        var next = payload; next.schemaVersion = 3
        next.basis = GoalPlanDecisionBasisV2(origin: .adjustment, confirmedAt: Date(), selectedChangeSummaries: ["用户修改本目标约定"])
        let row = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goalID,
            sourceSessionID: nil, revisionNumber: Int(base.revisionNumber) + 1, baseRevisionID: base.id,
            operationID: operationID, effectiveFrom: Date(), payload: next, legacySummary: nil)
        goal.desiredOutcome = next.intent.successCriteria
        goal.deadline = next.intent.deadline
        if let target = next.resultSource?.targetValue { goal.metricTargetValueDouble = target }
        goal.updatedAt = Date()
        try context.save()
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSUpdatedObjectsKey: [goal.objectID], NSInsertedObjectsKey: [row.objectID]], into: [source])
        if contextOverride == nil { GoalRepository.shared.loadGoals() }
        NotificationCenter.default.post(name: .goalDataDidChange, object: nil)
    }
}
