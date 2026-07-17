//
//  Topic+CoreDataClass.swift
//  Holo
//
//  想法主题实体
//  多条想法的长期线索聚合（v1a 只建表，不实现主题匹配/摘要/升级流程）
//

import Foundation
import CoreData

@objc(Topic)
class Topic: NSManagedObject, @unchecked Sendable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Topic> {
        NSFetchRequest<Topic>(entityName: "Topic")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var summary: String?
    @NSManaged var status: String
    @NSManaged var confidence: Double
    @NSManaged var associatedTagNames: String?
    @NSManaged var thoughtCount: Int16
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Relationships

    @NSManaged var thoughts: NSSet?
    @NSManaged var associatedTags: NSSet?
    @NSManaged var mergedToTopic: Topic?
    @NSManaged var mergedFromTopics: NSSet?
}

// MARK: - Core Data Generated Accessors

extension Topic {

    // MARK: - Thoughts Accessors

    @objc(addThoughtsObject:)
    @NSManaged func addThoughts(_ value: Thought)

    @objc(removeThoughtsObject:)
    @NSManaged func removeThoughts(_ value: Thought)

    @objc(addThoughts:)
    @NSManaged func addThoughts(_ values: Set<Thought>)

    @objc(removeThoughts:)
    @NSManaged func removeThoughts(_ values: Set<Thought>)

    // MARK: - AssociatedTags Accessors

    @objc(addAssociatedTagsObject:)
    @NSManaged func addAssociatedTags(_ value: ThoughtTag)

    @objc(removeAssociatedTagsObject:)
    @NSManaged func removeAssociatedTags(_ value: ThoughtTag)

    @objc(addAssociatedTags:)
    @NSManaged func addAssociatedTags(_ values: Set<ThoughtTag>)

    @objc(removeAssociatedTags:)
    @NSManaged func removeAssociatedTags(_ values: Set<ThoughtTag>)

    // MARK: - MergedFromTopics Accessors

    @objc(addMergedFromTopicsObject:)
    @NSManaged func addMergedFromTopics(_ value: Topic)

    @objc(removeMergedFromTopicsObject:)
    @NSManaged func removeMergedFromTopics(_ value: Topic)

    @objc(addMergedFromTopics:)
    @NSManaged func addMergedFromTopics(_ values: Set<Topic>)

    @objc(removeMergedFromTopics:)
    @NSManaged func removeMergedFromTopics(_ values: Set<Topic>)
}

// MARK: - Status 枚举

extension Topic {

    /// 主题状态类型
    enum TopicStatus: String, CaseIterable {
        case candidate  // 候选主题，证据不足
        case active     // 已达到阈值，正式展示
        case hidden     // 用户隐藏
        case merged     // 已合并到其他主题
    }

    /// 便捷访问 status 枚举
    var statusEnum: TopicStatus {
        get { TopicStatus(rawValue: status) ?? .candidate }
        set { status = newValue.rawValue }
    }
}

// MARK: - 关联标签展示缓存

extension Topic {

    /// 从 associatedTags 关系重算 associatedTagNames 展示缓存（逗号拼接，排序保证稳定）
    /// 标签删除/重命名/合并后必须调用，否则 AI 对话工具会读到脏名字
    func refreshAssociatedTagNamesCache() {
        let names = (associatedTags as? Set<ThoughtTag>)?
            .map(\.name)
            .sorted() ?? []
        associatedTagNames = names.isEmpty ? nil : names.joined(separator: ",")
    }
}
