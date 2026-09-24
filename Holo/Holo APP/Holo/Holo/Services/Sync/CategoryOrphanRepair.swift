//
//  CategoryOrphanRepair.swift
//  Holo
//
//  孤儿分类修复：活着的二级分类其父一级仍处于软删/缺失状态时联动恢复父一级。
//
//  「活子+死父」是异常中间态（正常删除流程会整组处置），来源是历史版本
//  回收站部分恢复不联动父级。危害：统计分析按一级分类聚合时，父一级不在
//  活分类缓存里，二级分类会冒充一级混入饼图第一层（2026-09-25 东林实报）。
//
//  沙箱隔离原则的读路径配套：回收站（软删态）里的分类不得影响线上统计，
//  数据侧把孤儿拉回正常态，比在每个读路径各自兜底更根治。
//

import Foundation
import CoreData

nonisolated enum CategoryOrphanRepair {

    struct Result {
        /// 联动恢复的父一级数量
        var restoredParents = 0
        /// 父行彻底缺失（悬空 parentId）的子分类数：无法自动修复，仅日志暴露
        var danglingChildren = 0
    }

    static func repair(in context: NSManagedObjectContext) throws -> Result {
        var result = Result()

        let childRequest = NSFetchRequest<Category>(entityName: "Category")
        childRequest.predicate = NSPredicate(format: "parentId != nil AND deletedAt == nil")
        let children = try context.fetch(childRequest)
        guard !children.isEmpty else { return result }

        let parentIDs = Array(Set(children.compactMap(\.parentId)))
        let parentRequest = NSFetchRequest<Category>(entityName: "Category")
        parentRequest.predicate = NSPredicate(
            format: "id IN %@", parentIDs as [UUID]
        )
        // 含软删行：孤儿判定需要看到「父在回收站里」；活父正常命中后无需处理。
        // 同 id 多行（iCloud 同步副本）时优先取活行：已有活父就不该再复活死行，
        // 否则会给副本修复引擎制造新副本
        let parentsByID = Dictionary(
            grouping: try context.fetch(parentRequest),
            by: \.id
        ).mapValues { rows in
            rows.first { $0.deletedAt == nil } ?? rows[0]
        }

        for child in children {
            guard let parentId = child.parentId else { continue }
            guard let parent = parentsByID[parentId] else {
                result.danglingChildren += 1
                continue
            }
            if parent.deletedAt != nil {
                parent.clearDeletedMark()
                result.restoredParents += 1
            }
        }

        guard result.restoredParents > 0 else { return result }
        try context.save()
        return result
    }
}
