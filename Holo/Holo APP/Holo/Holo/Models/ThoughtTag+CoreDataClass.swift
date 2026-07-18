//
//  ThoughtTag+CoreDataClass.swift
//  Holo
//
//  观点模块 - 标签实体类
//

import Foundation
import CoreData

@objc(ThoughtTag)
class ThoughtTag: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTag> {
        NSFetchRequest<ThoughtTag>(entityName: "ThoughtTag")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var color: String?
    @NSManaged var usageCount: Int16
    @NSManaged var lastUsedAt: Date?              // 最近使用时间（# 候选「最近使用」排序）

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
