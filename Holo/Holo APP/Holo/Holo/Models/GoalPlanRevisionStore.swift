//
//  GoalPlanRevisionStore.swift
//  Holo
//
//  目标决策版本存储（方案任务 2 / §2.4）
//
//  不绑定 MainActor：确认页主线程用 viewContext，原子提交链路在
//  newBackgroundContext.perform 内调用同一 API，context 归属由调用方保证。
//

import Foundation
import CoreData

final class GoalPlanRevisionStore {

    static let shared = GoalPlanRevisionStore()

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    private init() {
        self.context = CoreDataStack.shared.viewContext
    }

    /// 追加一版决策记录。revisionNumber 由调用方按 `sessionID + revision` 稳定计算；
    /// 同一 (goalID, revisionNumber) 已存在时幂等返回，不重复创建
    @discardableResult
    func record(goalID: UUID,
                sourceSessionID: UUID,
                revisionNumber: Int,
                summary: GoalWorkshopDecisionSummaryV1) throws -> GoalPlanRevisionMO {
        if let existing = find(goalID: goalID, revisionNumber: Int64(revisionNumber)) {
            return existing
        }
        let mo = GoalPlanRevisionMO.make(
            in: context,
            goalID: goalID,
            sourceSessionID: sourceSessionID,
            revisionNumber: revisionNumber,
            summary: summary
        )
        try context.save()
        return mo
    }

    /// 某目标的全部决策版本（时间正序）；旧 Goal 无版本返回空数组
    func loadRevisions(goalID: UUID) throws -> [GoalWorkshopDecisionSummaryV1] {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND deletedAt == nil",
            goalID as CVarArg
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "revisionNumber", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true),
        ]
        let rows = (try? context.fetch(request)) ?? []
        // 同版本 iCloud 副本去重（版本号+session 相同视为同一条）
        var seen = Set<String>()
        var summaries: [GoalWorkshopDecisionSummaryV1] = []
        for row in rows {
            let key = "\(row.sourceSessionID.uuidString)#\(row.revisionNumber)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if let summary = try? row.decodeSummary() {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// 最新一版的版本号（无记录返回 0）
    func latestRevisionNumber(goalID: UUID) -> Int {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND deletedAt == nil",
            goalID as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "revisionNumber", ascending: false)]
        request.fetchLimit = 1
        return Int((try? context.fetch(request))?.first?.revisionNumber ?? 0)
    }

    private func find(goalID: UUID, revisionNumber: Int64) -> GoalPlanRevisionMO? {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND revisionNumber == %lld AND deletedAt == nil",
            goalID as CVarArg, revisionNumber
        )
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - v2 生效计划（2026-10-20 目标闭环）

    /// 某目标最新一条版本行（含 v1 旧行）；无记录返回 nil
    func latestRevisionRow(goalID: UUID) -> GoalPlanRevisionMO? {
        Self.latestRevisionRow(goalID: goalID, in: context)
    }

    nonisolated static func latestRevisionRow(goalID: UUID, in context: NSManagedObjectContext) -> GoalPlanRevisionMO? {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(format: "goalID == %@ AND deletedAt == nil", goalID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "revisionNumber", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 按 id 取版本行
    nonisolated static func revisionRow(id: UUID, in context: NSManagedObjectContext) -> GoalPlanRevisionMO? {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 同 operationID 的已提交版本（幂等命中）
    nonisolated static func revisionRow(operationID: UUID, goalID: UUID, in context: NSManagedObjectContext) -> GoalPlanRevisionMO? {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND operationID == %@ AND deletedAt == nil",
            goalID as CVarArg, operationID as CVarArg
        )
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// 同一父版本下已提交的子版本（多设备并发分支检测：>1 条即分叉）
    nonisolated static func childRevisionRows(baseRevisionID: UUID, goalID: UUID, in context: NSManagedObjectContext) -> [GoalPlanRevisionMO] {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(
            format: "goalID == %@ AND baseRevisionID == %@ AND deletedAt == nil",
            goalID as CVarArg, baseRevisionID as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let rows = (try? context.fetch(request)) ?? []
        var seen = Set<UUID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// 全部版本行（时间正序，iCloud 副本按 id 去重）
    nonisolated static func allRevisionRows(goalID: UUID, in context: NSManagedObjectContext) -> [GoalPlanRevisionMO] {
        let request = NSFetchRequest<GoalPlanRevisionMO>(entityName: "GoalPlanRevisionMO")
        request.predicate = NSPredicate(format: "goalID == %@ AND deletedAt == nil", goalID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "revisionNumber", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true),
        ]
        let rows = (try? context.fetch(request)) ?? []
        var seen = Set<UUID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// 写入一条携带 v2 计划 payload 的版本行（不保存；由统一提交器一次 save）
    @discardableResult
    nonisolated static func makeRevisionRow(in context: NSManagedObjectContext,
                                            goalID: UUID,
                                            sourceSessionID: UUID?,
                                            revisionNumber: Int,
                                            baseRevisionID: UUID?,
                                            operationID: UUID?,
                                            effectiveFrom: Date,
                                            payload: GoalPlanPayloadV2,
                                            legacySummary: GoalWorkshopDecisionSummaryV1?) throws -> GoalPlanRevisionMO {
        let mo = GoalPlanRevisionMO(context: context)
        mo.id = UUID()
        mo.schemaVersion = GoalWorkshopSchemaDefaults.payloadSchemaVersion
        mo.goalID = goalID
        mo.sourceSessionID = sourceSessionID ?? GoalWorkshopSchemaDefaults.zeroUUID
        mo.revisionNumber = Int64(revisionNumber)
        if let legacySummary {
            mo.decisionSummaryJSON = (try? JSONEncoder().encode(legacySummary)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } else {
            mo.decisionSummaryJSON = ""
        }
        mo.planPayloadJSON = try GoalPlanPayloadCodec.encode(payload)
        mo.baseRevisionID = baseRevisionID
        mo.operationID = operationID
        mo.effectiveFrom = effectiveFrom
        let now = Date()
        mo.createdAt = now
        mo.updatedAt = now
        return mo
    }
}

extension GoalPlanRevisionMO {
    /// 解码 v2 计划 payload；旧行（仅 v1 摘要）返回 .legacyDecisionSummary
    var planPayloadDecodeResult: GoalPlanPayloadDecodeResult {
        guard let planPayloadJSON, !planPayloadJSON.isEmpty else {
            return decisionSummaryJSON.isEmpty ? .empty : .legacyDecisionSummary
        }
        return GoalPlanPayloadCodec.decode(planPayloadJSON)
    }

    var planPayloadV2: GoalPlanPayloadV2? {
        if case .current(let payload) = planPayloadDecodeResult { return payload }
        return nil
    }
}
