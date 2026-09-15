//
//  NewUserActivationState.swift
//  Holo
//
//  新用户激活判定：全库（交易/任务/想法/习惯）无任何未软删记录时，
//  用户仍处于「未产生第一条记录」状态。供首页第一步行动卡与首次记录庆祝使用。
//  口径：任一实体存在即视为已激活；回收站软删行（deletedAt 非 nil）不计入。
//

import CoreData
import Foundation

enum NewUserActivationState {

    /// 四个实体均有 deletedAt 软删字段（索引见 CoreDataStack+*Entities.swift）
    private static let trackedEntities = ["Transaction", "TodoTask", "Thought", "Habit"]

    /// 用户是否已产生任何一条记录（任一实体存在未软删行即 true）
    static func hasAnyRecord(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) -> Bool {
        trackedEntities.contains { activeCount($0, limit: 1, context: context) > 0 }
    }

    /// 当前库中未软删交易是否恰好只有一条（= 人生第一笔刚落库）
    static func isFirstTransactionEver(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) -> Bool {
        activeCount("Transaction", limit: 2, context: context) == 1
    }

    private static func activeCount(_ entityName: String, limit: Int, context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.fetchLimit = limit
        return (try? context.count(for: request)) ?? 0
    }
}
