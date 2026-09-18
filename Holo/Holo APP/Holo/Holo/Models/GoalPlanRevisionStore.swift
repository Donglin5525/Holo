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
}
