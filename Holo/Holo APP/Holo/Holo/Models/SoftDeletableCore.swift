//
//  SoftDeletableCore.swift
//  Holo
//
//  软删除协议 + 习惯/待办链实体的软删除属性声明。
//  自 SoftDeletable.swift 拆出：小组件扩展进程只挂本文件即可获得习惯/待办链的
//  软删除语义，不必连带其余约 25 个实体的扩展（那些留在 SoftDeletable.swift，仅 App）。
//

import Foundation
import CoreData

// MARK: - Protocol

/// 支持统一软删除的实体协议
protocol SoftDeletable: NSManagedObject {
    /// 删除时刻；nil = 正常数据
    var deletedAt: Date? { get set }
    /// 清空批次 ID；nil = 非批次删除（单条软删）
    var deletedBatchId: UUID? { get set }
}

extension SoftDeletable {

    /// 是否已删除（含回收站与单条软删）
    var isRecycleDeleted: Bool { deletedAt != nil }

    /// 是否在回收站中（批次删除、可恢复）
    var isInRecycleBin: Bool { deletedAt != nil && deletedBatchId != nil }

    /// 打软删标记
    func markDeleted(batchId: UUID?, at date: Date = Date()) {
        deletedAt = date
        deletedBatchId = batchId
    }

    /// 恢复（清除软删标记）
    func clearDeletedMark() {
        deletedAt = nil
        deletedBatchId = nil
    }

    /// 通用「未删除」谓词，供各 Repository 查询复用
    static var notDeletedPredicate: NSPredicate {
        NSPredicate(format: "deletedAt == nil")
    }

    /// 通用「回收站批次内」谓词
    static func inBatchPredicate(_ batchId: UUID) -> NSPredicate {
        NSPredicate(format: "deletedBatchId == %@", batchId as CVarArg)
    }
}

// MARK: - 习惯 / 待办链（小组件共享）

extension TodoTask: SoftDeletable {
    @NSManaged var deletedBatchId: UUID?
}

extension TodoList: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension TodoFolder: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension TodoTag: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension Habit: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HabitRecord: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}
