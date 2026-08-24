//
//  SoftDeletable.swift
//  Holo
//
//  统一软删除协议（数据清理与回收站功能）
//
//  全库统一约定：
//  - deletedAt == nil        → 正常数据
//  - deletedAt != nil        → 已删除（值为删除时刻）
//  - deletedBatchId != nil   → 清空批次删除（回收站展示、30 天内可恢复）
//  - deletedBatchId == nil   → 单条软删（回收站不展示、30 天后物理清理）
//
//  实体子类的属性声明集中在本文件（@NSManaged 允许在 NSManagedObject 子类的
//  extension 中声明），避免分散改动约 25 个子类文件。
//  对应模型字段定义见各 CoreDataStack+*Entities.swift 工厂中的
//  CoreDataStack.makeSoftDeleteAttributes()。
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

// MARK: - Finance

extension Transaction: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension Account: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension Category: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension Budget: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension SpendingProject: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Thoughts

extension Thought: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension ThoughtTag: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension Topic: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Todo
// TodoTask.deletedAt 已在 TodoTask+CoreDataClass.swift 声明，这里仅补批次字段

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

// MARK: - Habits

extension Habit: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HabitRecord: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Anniversary
// Anniversary 旧字段 isSoftDeleted 保留兼容，读写统一迁移到 deletedAt

extension Anniversary: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Goals

extension Goal: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension GoalMetricLog: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Chat

extension ChatMessage: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Memory Insights

extension MemoryInsight: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension MemoryInsightFeedback: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// MARK: - Holo Memory（六实体；主库与敏感库共用同一模型）

extension HoloMemoryRecordMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HoloMemoryEvidenceMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HoloMemoryAnchorAliasMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HoloMemoryObservationRunMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension HoloMemoryTombstoneMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

// 注：HoloMemoryControlStateMO 为全局运行状态单例（非用户数据），不参与软删除。

// MARK: - LifePlan

extension LifePlanMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension PlanPriorityMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension PlanActionMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension PlanSignalMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension PlanFeedbackMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}

extension PlanRunMO: SoftDeletable {
    @NSManaged var deletedAt: Date?
    @NSManaged var deletedBatchId: UUID?
}
