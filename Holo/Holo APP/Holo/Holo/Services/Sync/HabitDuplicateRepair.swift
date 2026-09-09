import CoreData
import Foundation

/// 仅合并身份与内容均相同的习惯副本，不按打卡数据猜测归属。
/// 调用方必须在 context 队列执行；云端记录名作为稳定排序依据，避免两台设备各删一份。
/// 磁贴墙等列表以习惯 id 为身份键，同 id 副本曾导致整墙渲染错乱（2026-09-09 真机实锤）。
nonisolated enum HabitDuplicateRepair {
    struct Result {
        var removed = 0
        var conflictingGroups = 0
        var deferredGroups = 0
        var remapped = 0
        var removedRecords = 0
    }

    static func repair(
        in context: NSManagedObjectContext,
        recordName: (NSManagedObjectID) -> String?
    ) throws -> Result {
        // 不把正在编辑、尚未保存的用户操作连带提交。
        guard !context.hasChanges else { return Result(deferredGroups: 1) }
        var result = Result()

        let request = NSFetchRequest<NSManagedObject>(entityName: "Habit")
        request.returnsObjectsAsFaults = false
        let rows = try context.fetch(request)

        var plans: [(survivor: NSManagedObject, latest: Date?, duplicates: [NSManagedObject])] = []
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
                Array(sorted.dropFirst().map { $0.0 })
            ))
        }

        // 记录处理必须先于删除：习惯删除是级联删除，副本挂着的打卡记录会陪葬。
        // 保留项已有同 id 记录 → 副本记录是同步副本，一并删除（否则合并后双份计打卡）；
        // 否则改挂到保留项。
        for plan in plans {
            var survivorRecordIds = recordIds(of: plan.survivor)
            for duplicate in plan.duplicates {
                let records = (duplicate.value(forKey: "records") as? Set<NSManagedObject>) ?? []
                for record in records {
                    if let recordId = record.value(forKey: "id") as? UUID {
                        if survivorRecordIds.contains(recordId) {
                            context.delete(record)
                            result.removedRecords += 1
                            continue
                        }
                        survivorRecordIds.insert(recordId)
                    }
                    record.setValue(plan.survivor, forKey: "habit")
                    result.remapped += 1
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

    private static func recordIds(of habit: NSManagedObject) -> Set<UUID> {
        let records = (habit.value(forKey: "records") as? Set<NSManagedObject>) ?? []
        return Set(records.compactMap { $0.value(forKey: "id") as? UUID })
    }

    private static func sameContent(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        // updatedAt 可能只因旧迁移被刷新；实际内容、删除状态和导入来源必须全部一致。
        for key in lhs.entity.attributesByName.keys where key != "updatedAt" {
            guard equal(lhs.value(forKey: key), rhs.value(forKey: key)) else { return false }
        }
        // to-many（records）是对侧 to-one 的投影，副本各自的集合必然不同，按集合比会永远冲突。
        // to-one（goal）按目标的稳定 id 比对身份，不能按对象指针比对。
        for relation in lhs.entity.relationshipsByName.values where relation.maxCount == 1 {
            let left = lhs.value(forKey: relation.name) as? NSManagedObject
            let right = rhs.value(forKey: relation.name) as? NSManagedObject
            switch (left, right) {
            case (nil, nil):
                continue
            case let (left?, right?):
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
