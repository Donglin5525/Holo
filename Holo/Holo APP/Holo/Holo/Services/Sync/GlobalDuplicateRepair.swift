//
//  GlobalDuplicateRepair.swift
//  Holo
//
//  全实体通用同步副本修复引擎
//

import CoreData
import Foundation

/// 库迁 AppGroup 事故（2026-09-08）的全量副本根治收口。
/// 此前逐域手写修复器（财务/习惯/想法）各覆盖一域，任务/洞察/纪念日/目标/聊天等
/// 域的存量副本无人清理（2026-09-10 任务筛选菜单重复项实锤）。本引擎由模型元数据
/// 驱动，一次覆盖全部 UUID 主键实体，语义与手写修复器完全一致：
///
/// - 按 `id` UUID 分组；内容全等（属性 + to-one 目标 id）才合并，冲突组保守保留只计数；
/// - 云端 recordName 排序定保留项（双端确定性，防互删），同步身份未建立的组延迟；
/// - 保留项 updatedAt 取组内 max（触发导出同步）；
/// - 挂子行（to-many + 对侧 to-one 反向）：独有 id 改挂保留项（防级联陪葬/断链），
///   同 id 副本行不动，随副本删除自灭；
/// - 共享目标（to-many + 对侧 to-many）：副本独有目标并回保留项集合（防 nullify 脱离）；
/// - 附件等外部资源从不删除：引擎只动数据库行。
///
/// 逐域手写修复器保留为安全网（本引擎先行合并后它们自然空转），长期可退役。
/// 每实体独立 save：单实体失败回滚自身并继续其余实体。
/// 调用方必须在 context 队列执行（挂 FinanceRepository.runRepairPass 同一轮询）。
nonisolated enum GlobalDuplicateRepair {
    struct Result {
        var removed = 0
        var reattachedChildren = 0
        var reattachedShared = 0
        var conflictingGroups = 0
        var deferredGroups = 0
        /// 实体名 → 移除行数（日志定位用）
        var removedByEntity: [String: Int] = [:]
    }

    /// 覆盖范围不由名单硬编码，而是运行时从模型自发现：凡主键为 UUID `id` 的实体
    /// 一律纳入（2026-09-10 与 CoreDataStack 程序化模型对账共 38 个）。
    /// 无 UUID 主键的实体不在引擎范围：UserPreferenceEntity/CategoryMappingRecordEntity/
    /// CategoryInductionRuleEntity/HomeIconConfig/HoloMemory 五组，各有专用修复或独立机制。
    /// 从模型推导还保证新增实体自动被覆盖、名单永不与模型漂移，也不会在实体不全的
    /// 环境上 fetch 出无法捕获的异常。
    static func repair(
        in context: NSManagedObjectContext,
        recordName: (NSManagedObjectID) -> String?
    ) throws -> Result {
        // 不把正在编辑、尚未保存的用户操作连带提交。整轮只报一次（逐实体守卫只为兜底）。
        guard !context.hasChanges else { return Result(deferredGroups: 1) }
        var total = Result()
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { return total }
        let entityNames = model.entities
            .filter { $0.attributesByName["id"]?.attributeType == .UUIDAttributeType }
            .compactMap(\.name)
            .sorted()
        for entityName in entityNames {
            do {
                let result = try repairEntity(entityName, in: context, recordName: recordName)
                if result.removed > 0 {
                    total.removedByEntity[entityName] = result.removed
                }
                total.removed += result.removed
                total.reattachedChildren += result.reattachedChildren
                total.reattachedShared += result.reattachedShared
                total.conflictingGroups += result.conflictingGroups
                total.deferredGroups += result.deferredGroups
            } catch {
                NSLog("全局同步副本修复 %@ 未保存：%@", entityName, error.localizedDescription)
            }
        }
        return total
    }

    static func repairEntity(
        _ entityName: String,
        in context: NSManagedObjectContext,
        recordName: (NSManagedObjectID) -> String?
    ) throws -> Result {
        // 不把正在编辑、尚未保存的用户操作连带提交。
        guard !context.hasChanges else { return Result(deferredGroups: 1) }
        var result = Result()

        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
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
            // CheckItem 等实体没有 updatedAt 字段，KVC 直读会抛 NSUnknownKeyException。
            let latest = group.compactMap { row -> Date? in
                guard row.entity.attributesByName["updatedAt"] != nil else { return nil }
                return row.value(forKey: "updatedAt") as? Date
            }.max()
            plans.append((sorted[0].0, latest, Array(sorted.dropFirst().map { $0.0 })))
        }

        // 合并阶段：挂子行改挂、共享目标并回，全部成功后才删除副本。
        for plan in plans {
            let survivor = plan.survivor
            for duplicate in plan.duplicates {
                for relation in duplicate.entity.relationshipsByName.values where relation.isToMany {
                    guard let related = duplicate.value(forKey: relation.name) as? Set<NSManagedObject>,
                          !related.isEmpty else { continue }
                    let survivorIds = Set(
                        ((survivor.value(forKey: relation.name) as? Set<NSManagedObject>) ?? [])
                            .compactMap { ($0.value(forKey: "id") as? UUID) ?? UUID() }
                    )
                    if let inverse = relation.inverseRelationship, !inverse.isToMany {
                        // 挂子行：独有 id 改挂保留项；同 id 副本行随副本删除自灭。
                        for child in related {
                            let childId = (child.value(forKey: "id") as? UUID) ?? UUID()
                            guard !survivorIds.contains(childId) else { continue }
                            child.setValue(survivor, forKey: inverse.name)
                            result.reattachedChildren += 1
                        }
                    } else {
                        // 共享目标（对侧 to-many 或无反向）：副本独有的并回保留项。
                        for target in related {
                            let targetId = (target.value(forKey: "id") as? UUID) ?? UUID()
                            guard !survivorIds.contains(targetId) else { continue }
                            (survivor.value(forKey: relation.name) as? NSMutableSet)?.add(target)
                            result.reattachedShared += 1
                        }
                    }
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

    /// 内容判等：除 updatedAt 外全部属性一致，且 to-one 关系按目标 id 比身份
    /// （重复导入的副本指向目标副本，同一 id 不同对象，按指针比会永远冲突）。
    /// to-many 是对侧 to-one 的投影或共享集合，不参与相等性比较（合并语义是改挂/并集）。
    private static func sameContent(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
        for key in lhs.entity.attributesByName.keys where key != "updatedAt" {
            guard equal(lhs.value(forKey: key), rhs.value(forKey: key)) else { return false }
        }
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
