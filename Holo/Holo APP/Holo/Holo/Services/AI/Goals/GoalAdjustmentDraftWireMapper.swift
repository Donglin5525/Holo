//
//  GoalAdjustmentDraftWireMapper.swift
//  Holo
//
//  目标闭环 §6.5：云端修正草案线上形态 → GoalAdjustmentDraftV2。
//  服务端已做白名单消毒，这里是客户端第二道闸：目标/计划版本必须与 goalScope 一致，
//  操作形状再过一次 validateShape，日期按 ISO8601 解析；任何一项不合规丢该操作，
//  全部无效则不挂草案（报告仍可读，只是没有「查看调整」入口）。
//

import Foundation

enum GoalAdjustmentDraftWireMapper {

    typealias Wire = HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudGoalAdjustmentDraft

    static let maxOperations = 12

    static func map(_ wire: Wire?, scope: HoloAgentGoalScope, reportMessageID: UUID, now: Date = Date()) -> GoalAdjustmentDraftV2? {
        guard let wire else { return nil }
        guard let goalID = UUID(uuidString: wire.goalID), goalID == scope.goalID,
              let baseRevisionID = UUID(uuidString: wire.baseRevisionID), baseRevisionID == scope.planRevisionID else {
            return nil
        }
        let draftID = UUID(uuidString: wire.draftID) ?? UUID()
        let createdAt = wire.createdAt.flatMap(parseDate) ?? now
        let expiresAt = wire.expiresAt.flatMap(parseDate) ?? createdAt.addingTimeInterval(GoalAdjustmentDraftV2.defaultValidity)
        let operations = (wire.operations ?? []).prefix(maxOperations).compactMap(mapOperation)
        guard !operations.isEmpty else { return nil }
        return GoalAdjustmentDraftV2(
            draftID: draftID,
            goalID: goalID,
            baseRevisionID: baseRevisionID,
            sourceReportMessageID: reportMessageID,
            sourceDigest: wire.sourceDigest ?? scope.sourceDigest,
            createdAt: createdAt,
            expiresAt: expiresAt,
            operations: Array(operations),
            expectedObservation: wire.expectedObservation?.nilIfBlank
        )
    }

    static func mapOperation(_ wire: Wire.Operation) -> GoalAdjustmentOperationV2? {
        guard let kind = GoalAdjustmentOperationKind(rawValue: wire.kind) else { return nil }
        var op = GoalAdjustmentOperationV2(id: wire.id.isEmpty ? UUID().uuidString : wire.id, kind: kind)
        op.targetEntityID = wire.targetEntityID.flatMap(UUID.init(uuidString:))
        op.targetBindingID = wire.targetBindingID.flatMap(UUID.init(uuidString:))
        op.draftRef = wire.draftRef?.nilIfBlank
        op.role = wire.role.flatMap(GoalPlanBindingRole.init(rawValue:))
        if let spec = wire.taskSpec {
            op.taskSpec = GoalAdjustmentTaskSpecV2(
                title: spec.title,
                dueDate: spec.dueDate.flatMap(parseDate),
                plannedStart: spec.plannedStart.flatMap(parseDate),
                plannedEnd: spec.plannedEnd.flatMap(parseDate),
                priority: spec.priority,
                note: spec.note?.nilIfBlank
            )
        }
        op.habitSpec = wire.habitSpec
        if let rule = wire.budgetRule, let accountID = UUID(uuidString: rule.accountID), rule.amount.isFinite, rule.amount > 0 {
            op.budgetRule = GoalBudgetRuleV2(
                bindingID: rule.bindingID.flatMap(UUID.init(uuidString:)) ?? op.targetBindingID ?? UUID(),
                accountID: accountID,
                categoryID: rule.categoryID.flatMap(UUID.init(uuidString:)),
                amount: Decimal(rule.amount),
                period: rule.period,
                startDate: rule.startDate.flatMap(parseDate) ?? Date(),
                reuseExistingBudgetID: rule.reuseExistingBudgetID.flatMap(UUID.init(uuidString:))
            )
        }
        if let schedule = wire.fundSchedule {
            let mapped = schedule.compactMap { installment -> GoalFundInstallmentV2? in
                guard let date = parseDate(installment.dueDate), installment.amount.isFinite, installment.amount > 0 else { return nil }
                return GoalFundInstallmentV2(dueDate: date, amount: Decimal(installment.amount), note: installment.note?.nilIfBlank)
            }
            op.fundSchedule = mapped.isEmpty ? nil : mapped
        }
        if let review = wire.review {
            op.review = GoalPlanReviewV2(
                cadenceDays: review.cadenceDays,
                nextReviewAt: review.nextReviewAt.flatMap(parseDate),
                observationWindowDays: review.observationWindowDays ?? GoalPlanReviewV2.defaultObservationWindowDays,
                verificationFocus: review.verificationFocus ?? []
            )
        }
        if let change = wire.criteriaChange {
            op.criteriaChange = GoalAdjustmentCriteriaChangeV2(
                newSuccessCriteria: change.newSuccessCriteria?.nilIfBlank,
                newTargetValue: change.newTargetValue,
                newDeadline: change.newDeadline.flatMap(parseDate),
                reason: change.reason?.nilIfBlank
            )
        }
        op.currentSummary = wire.currentSummary?.nilIfBlank
        op.proposedSummary = wire.proposedSummary?.nilIfBlank
        op.reason = wire.reason?.nilIfBlank
        op.appliesFrom = wire.appliesFrom.flatMap(parseDate)
        op.appliesThrough = wire.appliesThrough.flatMap(parseDate)
        op.affectedObjectTitle = wire.affectedObjectTitle?.nilIfBlank
        guard (try? op.validateShape()) != nil else { return nil }
        return op
    }

    static func parseDate(_ text: String) -> Date? {
        GoalPlanPayloadCodec.fractionalFormatter.date(from: text)
            ?? GoalPlanPayloadCodec.plainFormatter.date(from: text)
            ?? GoalWorkshopValidator.strictDayFormatter.date(from: text)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
