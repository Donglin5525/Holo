//
//  Thought+CoreDataClass.swift
//  Holo
//
//  观点模块 - 想法实体类
//

import Foundation
import CoreData

@objc(Thought)
class Thought: NSManagedObject {
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

    // 结构化内容（#/@ Token）
    @NSManaged var richContentJSON: String?        // 编辑器结构化事实源，nil=纯文本想法
    @NSManaged var firstLine: String?              // 首行摘要（@ 候选标题，保存时派生）
    @NSManaged var topicConfidence: Double         // 主题归属置信度：AI 写入，手动移入/确认置 1；<0.75 待确认
    @NSManaged var topicAssignmentReason: String?  // 主题归属理由（后端 v4 prompt 随结果返回的一句话依据）

    // 想法自动整理 V2（2026-09-05 方案 §7.2）索引元数据
    @NSManaged var indexRequestedHash: String?     // 发起整理时的正文版本标记
    @NSManaged var indexCompletedHash: String?     // 完成标记（含合法 0 标签），防开 App 重跑
    @NSManaged var indexOperationID: UUID?         // 本次逻辑任务操作 ID（服务端幂等对账）
    @NSManaged var indexAttemptCount: Int16        // 网络类失败重试计数（每正文版本最多额外 1 次）
    @NSManaged var indexNextAttemptAt: Date?       // 下次允许整理时间（预算窗口/退避，重启恢复用）
    @NSManaged var indexEngineVersion: String?     // 产生结果的引擎版本（thought_index_v2.1）

    // MARK: - Relationships

    @NSManaged var tags: NSSet?
    @NSManaged var references: NSSet?
    @NSManaged var referencedBy: NSSet?
    @NSManaged var tagAssignments: NSSet?          // ThoughtTagAssignment 中间实体
    @NSManaged var topics: NSSet?                   // Topic 多对多
    @NSManaged var attachments: NSSet?              // ThoughtAttachment 附件
    @NSManaged var createdTasks: NSSet?             // 由本想法转换而来的任务（to-many）
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
