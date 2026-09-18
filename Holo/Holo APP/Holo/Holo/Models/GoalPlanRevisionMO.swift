//
//  GoalPlanRevisionMO.swift
//  Holo
//
//  目标决策版本记录（方案任务 2 / §2.4）
//
//  每次用户确认保存/重规划后落一条：goalID + sourceSessionID + 版本号 + 决策摘要。
//  旧 Goal 无版本记录时详情页保持现有布局，loadRevisions 返回空数组。
//

import Foundation
import CoreData

/// 决策摘要值类型：确认页最终确认了什么（含用户在确认页的修改）
struct GoalWorkshopDecisionSummaryV1: Codable, Equatable {
    var schemaVersion: Int = Int(GoalWorkshopSchemaDefaults.payloadSchemaVersion)
    var definition: GoalWorkshopGoalDefinition?
    var selectedRouteTitle: String?
    var planTitle: String
    var successEvidence: String
    var assumptions: [String]
    var firstActionTitle: String?
    var selectedTaskTitles: [String]
    var selectedHabitNames: [String]
    var allowAIContext: Bool
    var confirmedAt: Date

    init(definition: GoalWorkshopGoalDefinition?,
         selectedRouteTitle: String?,
         planTitle: String,
         successEvidence: String,
         assumptions: [String],
         firstActionTitle: String?,
         selectedTaskTitles: [String],
         selectedHabitNames: [String],
         allowAIContext: Bool,
         confirmedAt: Date = Date()) {
        self.definition = definition
        self.selectedRouteTitle = selectedRouteTitle
        self.planTitle = planTitle
        self.successEvidence = successEvidence
        self.assumptions = assumptions
        self.firstActionTitle = firstActionTitle
        self.selectedTaskTitles = selectedTaskTitles
        self.selectedHabitNames = selectedHabitNames
        self.allowAIContext = allowAIContext
        self.confirmedAt = confirmedAt
    }
}

@objc(GoalPlanRevisionMO)
final class GoalPlanRevisionMO: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var schemaVersion: Int16
    @NSManaged var goalID: UUID
    @NSManaged var sourceSessionID: UUID
    @NSManaged var revisionNumber: Int64
    @NSManaged var decisionSummaryJSON: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?

    // MARK: - 构造与解码

    static func make(in context: NSManagedObjectContext,
                     goalID: UUID,
                     sourceSessionID: UUID,
                     revisionNumber: Int,
                     summary: GoalWorkshopDecisionSummaryV1) -> GoalPlanRevisionMO {
        let mo = GoalPlanRevisionMO(context: context)
        mo.id = UUID()
        mo.schemaVersion = GoalWorkshopSchemaDefaults.payloadSchemaVersion
        mo.goalID = goalID
        mo.sourceSessionID = sourceSessionID
        mo.revisionNumber = Int64(revisionNumber)
        mo.decisionSummaryJSON = (try? JSONEncoder().encode(summary)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        mo.createdAt = Date()
        mo.updatedAt = Date()
        return mo
    }

    func decodeSummary() throws -> GoalWorkshopDecisionSummaryV1 {
        guard let data = decisionSummaryJSON.data(using: .utf8) else {
            throw GoalWorkshopStoreError.corruptedPayload(sessionID: sourceSessionID)
        }
        let summary = try JSONDecoder().decode(GoalWorkshopDecisionSummaryV1.self, from: data)
        guard summary.schemaVersion <= Int(GoalWorkshopSchemaDefaults.payloadSchemaVersion) else {
            throw GoalWorkshopStoreError.incompatiblePayload(version: summary.schemaVersion)
        }
        return summary
    }
}
