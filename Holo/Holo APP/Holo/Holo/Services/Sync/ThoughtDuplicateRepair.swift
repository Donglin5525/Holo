import CoreData
import Foundation

/// 仅合并身份与内容均相同的想法副本（库迁 AppGroup 事故在想法域遗留的云端全量副本）。
/// 调用方必须在 context 队列执行；云端记录名作为稳定排序依据，避免两台设备各删一份。
/// 想法列表/统计以 id 为身份键，同 id 副本会让列表同一条想法出现两次（2026-09-10 真机实锤）。
nonisolated enum ThoughtDuplicateRepair {
    struct Result {
        var removed = 0
        var conflictingGroups = 0
        var deferredGroups = 0
        var reattachedTags = 0
        var reattachedChildren = 0
    }

    static func repair(
        in context: NSManagedObjectContext,
        recordName: (NSManagedObjectID) -> String?
    ) throws -> Result {
        // 不把正在编辑、尚未保存的用户操作连带提交。
        guard !context.hasChanges else { return Result(deferredGroups: 1) }
        var result = Result()

        let request = NSFetchRequest<NSManagedObject>(entityName: "Thought")
        request.returnsObjectsAsFaults = false
        let rows = try context.fetch(request)

        // 规划阶段只读：内容冲突与同步身份缺失的组不动，先算出全部合并计划。
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

        // 合并阶段：副本的共享目标（标签/主题）并回保留项；独有挂子行改挂保留项，
        // 同 id 的挂子行副本不动，随副本的 cascade 删除一并清掉（与保留项同 id 同内容）。
        // 任务关系是 nullify，同 id 任务副本脱离后由任务域修复器处理，这里只保链接不删任务。
        // 附件文件从不删除：同 id 副本行可能引用同一文件，删文件有误删保留项引用的风险。
        // 所有读取与改挂成功后再删除，避免后续失败留下半改状态。
        for plan in plans {
            let survivorTagIds = relatedIds(plan.survivor, "tags")
            let survivorTopicIds = relatedIds(plan.survivor, "topics")
            let survivorAssignmentIds = relatedIds(plan.survivor, "tagAssignments")
            let survivorAttachmentIds = relatedIds(plan.survivor, "attachments")
            let survivorReferenceIds = relatedIds(plan.survivor, "references")
                .union(relatedIds(plan.survivor, "referencedBy"))
            let survivorTaskIds = relatedIds(plan.survivor, "createdTasks")
            for duplicate in plan.duplicates {
                for tag in relatedRows(duplicate, "tags") where !survivorTagIds.contains(id(of: tag)) {
                    (plan.survivor.value(forKey: "tags") as? NSMutableSet)?.add(tag)
                    result.reattachedTags += 1
                }
                for topic in relatedRows(duplicate, "topics") where !survivorTopicIds.contains(id(of: topic)) {
                    (plan.survivor.value(forKey: "topics") as? NSMutableSet)?.add(topic)
                    result.reattachedTags += 1
                }
                for assignment in relatedRows(duplicate, "tagAssignments")
                where !survivorAssignmentIds.contains(id(of: assignment)) {
                    assignment.setValue(plan.survivor, forKey: "thought")
                    result.reattachedChildren += 1
                }
                for attachment in relatedRows(duplicate, "attachments")
                where !survivorAttachmentIds.contains(id(of: attachment)) {
                    attachment.setValue(plan.survivor, forKey: "thought")
                    result.reattachedChildren += 1
                }
                for reference in relatedRows(duplicate, "references")
                where !survivorReferenceIds.contains(id(of: reference)) {
                    reference.setValue(plan.survivor, forKey: "sourceThought")
                    result.reattachedChildren += 1
                }
                for reference in relatedRows(duplicate, "referencedBy")
                where !survivorReferenceIds.contains(id(of: reference)) {
                    reference.setValue(plan.survivor, forKey: "targetThought")
                    result.reattachedChildren += 1
                }
                for task in relatedRows(duplicate, "createdTasks")
                where !survivorTaskIds.contains(id(of: task)) {
                    task.setValue(plan.survivor, forKey: "sourceThought")
                    result.reattachedChildren += 1
                }
            }
        }
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

    private static func relatedRows(_ row: NSManagedObject, _ key: String) -> [NSManagedObject] {
        guard let rows = row.value(forKey: key) as? Set<NSManagedObject> else { return [] }
        return Array(rows)
    }

    private static func relatedIds(_ row: NSManagedObject, _ key: String) -> Set<UUID> {
        Set(relatedRows(row, key).compactMap { id(of: $0) })
    }

    private static func id(of row: NSManagedObject) -> UUID {
        (row.value(forKey: "id") as? UUID) ?? UUID()
    }

    private static func sameContent(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        // updatedAt 可能只因旧迁移被刷新；其余属性（含删除状态、整理状态、结构化内容）必须全部一致。
        // to-many 关系不做相等性比较：合并语义是并集改挂，冲突无从产生。
        for key in lhs.entity.attributesByName.keys where key != "updatedAt" {
            guard equal(lhs.value(forKey: key), rhs.value(forKey: key)) else { return false }
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
