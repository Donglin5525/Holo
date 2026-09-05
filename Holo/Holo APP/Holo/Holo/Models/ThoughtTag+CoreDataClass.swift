//
//  ThoughtTag+CoreDataClass.swift
//  Holo
//
//  观点模块 - 标签实体类
//

import Foundation
import CoreData

@objc(ThoughtTag)
class ThoughtTag: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTag> {
        NSFetchRequest<ThoughtTag>(entityName: "ThoughtTag")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var color: String?
    @NSManaged var usageCount: Int16
    @NSManaged var lastUsedAt: Date?              // 最近使用时间（# 候选「最近使用」排序）

    // 想法自动整理 V2（2026-09-05 方案 §7.2）概念语义层
    @NSManaged var semanticName: String?          // V2 平面展示名；旧 name 路径保持原值
    @NSManaged var semanticDefinition: String?    // 概念边界说明（非私人摘要）
    @NSManaged var aliasesJSON: String?           // 已验证等价表达（JSON 数组，仅 equivalent）
    @NSManaged var indexKind: String?             // user/auto/provisional/legacy
    @NSManaged var nameLockedByUser: Bool         // 用户命名/确认后 AI 不改名
    @NSManaged var mergedIntoTagID: UUID?         // 确定性重定向目标（读取时解析并防环）
    @NSManaged var autoSuggestionBlocked: Bool    // 用户全局拒绝自动使用（不自动过期）
    @NSManaged var autoCollectionHidden: Bool     // 仅隐藏合集入口，不影响打标/筛选

    // MARK: - Relationships

    @NSManaged var thoughts: NSSet?
    @NSManaged var assignments: NSSet?         // ThoughtTagAssignment 中间实体
    @NSManaged var associatedTopics: NSSet?    // Topic 关联标签
}

// MARK: - Core Data Generated Accessors

extension ThoughtTag {
    @objc(addThoughtsObject:)
    @NSManaged func addThoughts(_ value: Thought)

    @objc(removeThoughtsObject:)
    @NSManaged func removeThoughts(_ value: Thought)

    @objc(addThoughts:)
    @NSManaged func addThoughts(_ values: Set<Thought>)

    @objc(removeThoughts:)
    @NSManaged func removeThoughts(_ values: Set<Thought>)

    // MARK: - Assignments Accessors

    @objc(addAssignmentsObject:)
    @NSManaged func addAssignments(_ value: ThoughtTagAssignment)

    @objc(removeAssignmentsObject:)
    @NSManaged func removeAssignments(_ value: ThoughtTagAssignment)

    @objc(addAssignments:)
    @NSManaged func addAssignments(_ values: Set<ThoughtTagAssignment>)

    @objc(removeAssignments:)
    @NSManaged func removeAssignments(_ values: Set<ThoughtTagAssignment>)

    // MARK: - AssociatedTopics Accessors

    @objc(addAssociatedTopicsObject:)
    @NSManaged func addAssociatedTopics(_ value: Topic)

    @objc(removeAssociatedTopicsObject:)
    @NSManaged func removeAssociatedTopics(_ value: Topic)

    @objc(addAssociatedTopics:)
    @NSManaged func addAssociatedTopics(_ values: Set<Topic>)

    @objc(removeAssociatedTopics:)
    @NSManaged func removeAssociatedTopics(_ values: Set<Topic>)
}
