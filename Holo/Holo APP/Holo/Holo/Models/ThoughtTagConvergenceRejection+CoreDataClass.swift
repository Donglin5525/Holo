//
//  ThoughtTagConvergenceRejection+CoreDataClass.swift
//  Holo
//
//  观点主题归并「建议级拒绝」实体（P2.5）
//  幂等键 = 主题名 + 来源词集合（语义级，不含观点 ID/hash），随 iCloud 同步
//  拒绝过的归并建议在有效期内不再重复弹出（spec §6.4 决策 10）
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import Foundation
import CoreData

@objc(ThoughtTagConvergenceRejection)
class ThoughtTagConvergenceRejection: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTagConvergenceRejection> {
        NSFetchRequest<ThoughtTagConvergenceRejection>(entityName: "ThoughtTagConvergenceRejection")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    /// 归一化幂等键（主题名 + 排序后来源词集合），查询主源
    @NSManaged var suggestionKey: String
    /// 建议主题名（展示原文）
    @NSManaged var topicTitle: String
    /// 来源词逗号拼接（展示用，派生自 sourceTerms）
    @NSManaged var sourceTermsText: String?
    /// 拒绝时间
    @NSManaged var rejectedAt: Date
    /// 抑制有效期截止时间，过期后不再抑制
    @NSManaged var expiresAt: Date
    /// 记录创建时间
    @NSManaged var createdAt: Date
}
