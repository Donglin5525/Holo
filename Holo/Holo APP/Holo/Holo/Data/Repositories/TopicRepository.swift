//
//  TopicRepository.swift
//  Holo
//
//  观点主题 Repository（P1.5.1）
//  Topic 从「结构存在」变成「产品可用对象」：创建/查重/隐藏/合并/来源词
//  thoughtCount 不缓存，实时按 thoughts.count 算（spec 决策 14）
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import Foundation
import CoreData
import OSLog

final class TopicRepository {

    private let context: NSManagedObjectContext
    private let logger = Logger(subsystem: "com.holo.app", category: "TopicRepository")

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - 归一化查重键（运行时，不持久化）

    /// 标题归一化：trim + lowercased，作为运行时查重键（spec 决策 17，不加 canonicalKey）
    static func normalizedKey(title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - 创建 / 查重

    /// 创建主题（默认 candidate 状态）
    /// - Parameters:
    ///   - title: 主题标题
    ///   - sourceTerms: 来源词（写入 associatedTags 主源，可空）
    @discardableResult
    func create(title: String, sourceTerms: [String] = []) throws -> Topic {
        let topic = Topic(context: context)
        topic.id = UUID()
        topic.title = title
        topic.status = Topic.TopicStatus.candidate.rawValue
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        try context.save()

        if !sourceTerms.isEmpty {
            try setSourceTerms(topic: topic, tagNames: sourceTerms)
        }
        return topic
    }

    /// 幂等创建：归一化查重命中则复用，否则新建（spec 决策 17）
    @discardableResult
    func getOrCreateTopic(title: String, sourceTerms: [String] = []) throws -> Topic {
        if let existing = try getByTitle(title) { return existing }
        return try create(title: title, sourceTerms: sourceTerms)
    }

    /// 按标题归一化查询（仅 active / candidate 状态，排除 hidden / merged）
    func getByTitle(_ title: String) throws -> Topic? {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            [Topic.TopicStatus.active.rawValue, Topic.TopicStatus.candidate.rawValue]
        )
        let topics = try context.fetch(request)
        let key = Self.normalizedKey(title: title)
        return topics.first { Self.normalizedKey(title: $0.title) == key }
    }

    /// 所有可展示主题（active / candidate），按 thoughtCount 降序
    func fetchVisibleTopics() throws -> [Topic] {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            [Topic.TopicStatus.active.rawValue, Topic.TopicStatus.candidate.rawValue]
        )
        let topics = try context.fetch(request)
        return topics.sorted { thoughtCount(of: $0) > thoughtCount(of: $1) }
    }

    // MARK: - 更新 / 状态

    func updateTitle(_ topic: Topic, title: String) throws {
        topic.title = title
        topic.updatedAt = Date()
        try context.save()
    }

    /// 升为正式（candidate → active）
    func activate(_ topic: Topic) throws {
        topic.status = Topic.TopicStatus.active.rawValue
        topic.updatedAt = Date()
        try context.save()
    }

    /// 隐藏（→ hidden）
    func hide(_ topic: Topic) throws {
        topic.status = Topic.TopicStatus.hidden.rawValue
        topic.updatedAt = Date()
        try context.save()
    }

    // MARK: - 合并（幂等去重，spec 决策 17）

    /// 将 duplicate 合并进 keeper：thoughts + associatedTags 归到 keeper，duplicate 标 merged
    func merge(into keeper: Topic, from duplicate: Topic) throws {
        if let dupThoughts = duplicate.thoughts as? Set<Thought> {
            keeper.addThoughts(dupThoughts)
        }
        if let dupTags = duplicate.associatedTags as? Set<ThoughtTag> {
            keeper.addAssociatedTags(dupTags)
        }
        duplicate.status = Topic.TopicStatus.merged.rawValue
        duplicate.mergedToTopic = keeper
        keeper.updatedAt = Date()
        try context.save()
    }

    /// 扫描同 normalizedKey 的可展示 Topic，把后出现的合并进先出现的（App 启动 / 同步后调用）
    /// - Returns: 合并掉的重复 Topic 数
    @discardableResult
    func mergeDuplicateTopics() throws -> Int {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            [Topic.TopicStatus.active.rawValue, Topic.TopicStatus.candidate.rawValue]
        )
        let topics = try context.fetch(request)

        var seen: [String: Topic] = [:]
        var mergedCount = 0
        for topic in topics {
            let key = Self.normalizedKey(title: topic.title)
            if let keeper = seen[key] {
                try merge(into: keeper, from: topic)
                mergedCount += 1
            } else {
                seen[key] = topic
            }
        }
        return mergedCount
    }

    // MARK: - thoughtCount（实时算，不缓存，spec 决策 14）

    func thoughtCount(of topic: Topic) -> Int {
        (topic.thoughts as? Set<Thought>)?.count ?? 0
    }

    // MARK: - 来源词主源（P1.5.3 扩展，此处基础版）

    /// 设置主题来源词：get-or-create ThoughtTag → 写入 associatedTags（主源）
    /// associatedTagNames 由 associatedTags 派生（展示缓存，spec 决策 16）
    func setSourceTerms(topic: Topic, tagNames: [String]) throws {
        // 清空旧来源词关系
        if let oldTags = topic.associatedTags as? Set<ThoughtTag> {
            topic.removeAssociatedTags(oldTags)
        }
        // get-or-create 新来源词
        var resolved: [ThoughtTag] = []
        for name in tagNames where !name.isEmpty {
            resolved.append(try getOrCreateTag(name: name))
        }
        topic.addAssociatedTags(Set(resolved))
        topic.associatedTagNames = resolved.map { $0.name }.joined(separator: ",")
        topic.updatedAt = Date()
        try context.save()
    }

    /// get-or-create ThoughtTag（P1.5.3 提权 ThoughtRepository.getOrCreateTag 后可复用，此处本地实现）
    private func getOrCreateTag(name: String) throws -> ThoughtTag {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", name)
        request.fetchLimit = 1
        if let existing = try context.fetch(request).first { return existing }
        let tag = ThoughtTag(context: context)
        tag.id = UUID()
        tag.name = name
        tag.usageCount = 0
        return tag
    }
}
