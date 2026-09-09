import CoreData
import Foundation

/// 仅合并身份与内容均相同的财务副本，不按金额、日期或商户猜测重复。
/// 调用方必须在 context 队列执行；云端记录名作为稳定排序依据，避免两台设备各删一份。
nonisolated enum FinanceDuplicateRepair {
    struct Result {
        var removed = 0
        var conflictingGroups = 0
        var deferredGroups = 0
        var remapped = 0
    }

    /// 被引用的实体在前：交易副本与账户副本互指时，关系按目标 id 判等才能对上，
    /// 与删除顺序无关；改挂统一发生在所有删除之前。
    private static let entityNames = [
        "Account", "Category", "FinanceProject",
        "Budget", "SpendingProject", "Transaction"
    ]

    static func repair(
        in context: NSManagedObjectContext,
        recordName: (NSManagedObjectID) -> String?
    ) throws -> Result {
        // 不把正在编辑、尚未保存的用户操作连带提交。
        guard !context.hasChanges else { return Result(deferredGroups: 1) }
        var result = Result()
        var plans: [(survivor: NSManagedObject, latest: Date?, duplicates: [NSManagedObject])] = []
        var rowsByEntity: [String: [NSManagedObject]] = [:]

        // 预算/项目/分类均以 UUID 外键或同一 id 关联；保留同一 UUID 不改变业务归属。
        for entityName in entityNames {
            guard NSEntityDescription.entity(forEntityName: entityName, in: context) != nil else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.returnsObjectsAsFaults = false
            let rows = try context.fetch(request)
            rowsByEntity[entityName] = rows
            var groups: [UUID: [NSManagedObject]] = [:]
            for row in rows {
                guard let id = row.value(forKey: "id") as? UUID else { continue }
                groups[id, default: []].append(row)
            }
            for group in groups.values where group.count > 1 {
                guard let first = group.first, group.dropFirst().allSatisfy({ sameContent(first, $0) }) else {
                    result.conflictingGroups += 1
                    continue
                }
                let named = group.compactMap { row -> (NSManagedObject, String)? in
                    guard let name = recordName(row.objectID) else { return nil }
                    return (row, name)
                }
                // 等待同步身份建立，不能用各设备不同的本地行号选保留项。
                guard named.count == group.count, Set(named.map { $0.1 }).count == group.count else {
                    result.deferredGroups += 1
                    continue
                }
                let sorted = named.sorted { $0.1 < $1.1 }
                plans.append((
                    sorted[0].0,
                    group.compactMap { $0.value(forKey: "updatedAt") as? Date }.max(),
                    sorted.dropFirst().map { $0.0 }
                ))
            }
        }

        // 改挂先于删除：引用了账户/分类副本的普通账单（本身不重复）必须转挂保留项，
        // 否则副本删除后账单的账户/分类被 nullify 置空，用户要重新归账。
        var survivorByID: [NSManagedObjectID: NSManagedObject] = [:]
        for plan in plans {
            for duplicate in plan.duplicates { survivorByID[duplicate.objectID] = plan.survivor }
        }
        if !survivorByID.isEmpty {
            for (entityName, rows) in rowsByEntity {
                guard let entity = NSEntityDescription.entity(forEntityName: entityName, in: context) else { continue }
                for relation in entity.relationshipsByName.values where relation.maxCount == 1 {
                    for row in rows {
                        guard let target = row.value(forKey: relation.name) as? NSManagedObject,
                              let survivor = survivorByID[target.objectID],
                              target.objectID != survivor.objectID else { continue }
                        row.setValue(survivor, forKey: relation.name)
                        result.remapped += 1
                    }
                }
            }
        }

        // 所有读取与改挂成功后再修改，避免后续失败留下半改状态。
        for plan in plans {
            if let latest = plan.latest { plan.survivor.setValue(latest, forKey: "updatedAt") }
            for duplicate in plan.duplicates {
                context.delete(duplicate)
                result.removed += 1
            }
        }
        if result.removed > 0 {
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
        return result
    }

    private static func sameContent(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        // updatedAt 可能只因旧迁移被刷新；实际内容、删除状态和导入来源必须全部一致。
        for key in lhs.entity.attributesByName.keys where key != "updatedAt" {
            guard equal(lhs.value(forKey: key), rhs.value(forKey: key)) else { return false }
        }
        // to-many 是对侧 to-one 的投影，比 to-one 即可；账户副本各自的 transactions
        // 集合必然不同（一份指向原件一份指向副本），按集合比会永远冲突。
        for relation in lhs.entity.relationshipsByName.values where relation.maxCount == 1 {
            let left = lhs.value(forKey: relation.name) as? NSManagedObject
            let right = rhs.value(forKey: relation.name) as? NSManagedObject
            switch (left, right) {
            case (nil, nil):
                continue
            case let (left?, right?):
                // 重复导入的账单副本指向账户副本而非原件：按目标的稳定 id 比对身份，
                // 不能按对象指针比对。
                if left.entity.attributesByName["id"] != nil,
                   equal(left.value(forKey: "id"), right.value(forKey: "id")) {
                    continue
                }
                guard left.objectID == right.objectID else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left as NSObject, right as NSObject): return left.isEqual(right)
        default: return false
        }
    }
}
