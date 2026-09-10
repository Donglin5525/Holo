//
//  DuplicateRowFilter.swift
//  Holo
//
//  读路径对「同 id 多行副本」免疫的通用过滤器
//

import CoreData
import Foundation

/// 库迁 AppGroup 事故（2026-09-08）导致 CloudKit 全量副本，任何实体都可能同 id 多行。
/// 修复器合并存量副本之前（以及冲突组永不合并的残余），所有以 id 为身份键的列表读路径
/// 必须先经此过滤：SwiftUI ForEach 以 id 为键，重复键会把列表渲染打乱
/// （习惯磁贴错位、任务筛选菜单重复项均为真机实锤）。
///
/// 范围说明：本类型只在主 App target 编译。小组件 target 共享的文件
/// （HabitRepository/TodoCompletionCore）不可引用它，那些文件内用自带实现
/// （HabitRepository.deduplicatingCopies / deduplicatingRows）。
nonisolated enum DuplicateRowFilter {

    /// 同 id 副本只保留物理行号最小的一行（云端副本行号更大），保持传入顺序。
    /// 无 id 属性的行原样保留（无法判身份，不误删）。
    static func deduplicatingCopies<T: NSManagedObject>(_ rows: [T]) -> [T] {
        guard rows.count > 1 else { return rows }
        var survivorById: [UUID: T] = [:]
        for row in rows {
            guard let id = row.value(forKey: "id") as? UUID else { continue }
            if let existing = survivorById[id] {
                if physicalRowNumber(row) < physicalRowNumber(existing) {
                    survivorById[id] = row
                }
            } else {
                survivorById[id] = row
            }
        }
        guard survivorById.count != rows.count else { return rows }
        return rows.filter { row in
            guard let id = row.value(forKey: "id") as? UUID else { return true }
            return survivorById[id] === row
        }
    }

    /// 物理行号取自 objectID（即 SQLite Z_PK，落库后跨启动稳定）
    static func physicalRowNumber(_ row: NSManagedObject) -> Int {
        Int(row.objectID.uriRepresentation().lastPathComponent) ?? Int.max
    }
}
