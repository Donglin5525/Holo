//
//  Thought+CoreDataClass.swift
//  Holo
//
//  观点模块 - 想法实体类
//

import Foundation
import CoreData

@objc(Thought)
class Thought: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Thought> {
        NSFetchRequest<Thought>(entityName: "Thought")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var content: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var mood: String?
    @NSManaged var orderIndex: Int16
    @NSManaged var imageData: Data?
    @NSManaged var isSoftDeleted: Bool
    @NSManaged var isArchived: Bool

    // AI 自动整理状态
    @NSManaged var organizedStatus: String        // unprocessed/pending/processing/organized/failed/disabled/skipped
    @NSManaged var createdDeviceId: String?        // 创建该想法的设备 ID
    @NSManaged var organizationStartedAt: Date?    // AI 整理开始时间（用于 processing 超时恢复）

    // MARK: - Relationships

    @NSManaged var tags: NSSet?
    @NSManaged var references: NSSet?
    @NSManaged var referencedBy: NSSet?
    @NSManaged var tagAssignments: NSSet?          // ThoughtTagAssignment 中间实体
    @NSManaged var topics: NSSet?                   // Topic 多对多
    @NSManaged var attachments: NSSet?              // ThoughtAttachment 附件
}

// MARK: - Core Data Generated Accessors

extension Thought {
    // MARK: - Tags Accessors

    @objc(addTagsObject:)
    @NSManaged func addTags(_ value: ThoughtTag)

    @objc(removeTagsObject:)
    @NSManaged func removeTags(_ value: ThoughtTag)

    @objc(addTags:)
    @NSManaged func addTags(_ values: Set<ThoughtTag>)

    @objc(removeTags:)
    @NSManaged func removeTags(_ values: Set<ThoughtTag>)

    // MARK: - References Accessors

    @objc(addReferencesObject:)
    @NSManaged func addReferences(_ value: ThoughtReference)

    @objc(removeReferencesObject:)
    @NSManaged func removeReferences(_ value: ThoughtReference)

    @objc(addReferences:)
    @NSManaged func addReferences(_ values: Set<ThoughtReference>)

    @objc(removeReferences:)
    @NSManaged func removeReferences(_ values: Set<ThoughtReference>)

    // MARK: - ReferencedBy Accessors

    @objc(addReferencedByObject:)
    @NSManaged func addReferencedBy(_ value: ThoughtReference)

    @objc(removeReferencedByObject:)
    @NSManaged func removeReferencedBy(_ value: ThoughtReference)

    @objc(addReferencedBy:)
    @NSManaged func addReferencedBy(_ values: Set<ThoughtReference>)

    @objc(removeReferencedBy:)
    @NSManaged func removeReferencedBy(_ values: Set<ThoughtReference>)

    // MARK: - TagAssignments Accessors

    @objc(addTagAssignmentsObject:)
    @NSManaged func addTagAssignments(_ value: ThoughtTagAssignment)

    @objc(removeTagAssignmentsObject:)
    @NSManaged func removeTagAssignments(_ value: ThoughtTagAssignment)

    @objc(addTagAssignments:)
    @NSManaged func addTagAssignments(_ values: Set<ThoughtTagAssignment>)

    @objc(removeTagAssignments:)
    @NSManaged func removeTagAssignments(_ values: Set<ThoughtTagAssignment>)

    // MARK: - Topics Accessors

    @objc(addTopicsObject:)
    @NSManaged func addTopics(_ value: Topic)

    @objc(removeTopicsObject:)
    @NSManaged func removeTopics(_ value: Topic)

    @objc(addTopics:)
    @NSManaged func addTopics(_ values: Set<Topic>)

    @objc(removeTopics:)
    @NSManaged func removeTopics(_ values: Set<Topic>)

    // MARK: - Attachments Accessors

    @objc(addAttachmentsObject:)
    @NSManaged func addAttachments(_ value: ThoughtAttachment)

    @objc(removeAttachmentsObject:)
    @NSManaged func removeAttachments(_ value: ThoughtAttachment)

    @objc(addAttachments:)
    @NSManaged func addAttachments(_ values: Set<ThoughtAttachment>)

    @objc(removeAttachments:)
    @NSManaged func removeAttachments(_ values: Set<ThoughtAttachment>)
}

// MARK: - 想法附件便捷访问

extension Thought {

    /// 按 sortOrder 排序的附件列表（过滤已删除）
    var sortedAttachments: [ThoughtAttachment] {
        (attachments?.allObjects as? [ThoughtAttachment] ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}
