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

    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
    }

    // MARK: - 归一化查重键（运行时，不持久化）

    /// 标题归一化：trim + lowercased，作为运行时查重键（spec 决策 17，不加 canonicalKey）
    static func normalizedKey(title: String) -> String {
        ThoughtTagNormalizer.key(title)
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

    // MARK: - 删除

    /// 删除主题：想法回未归类、标签关联断开、自引用清理、删除实体
    /// 想法/标签本身不动；调用方负责用返回的 sourceTerms 写归并拒绝记录（防 AI 再造同名主题）
    /// - Parameter topic: 待删除主题
    /// - Returns: 删除结果（标题/来源词/摘除的想法关联数）
    @discardableResult
    func delete(_ topic: Topic) throws -> TopicDeletionResult {
        let result = TopicDeletionResult(
            title: topic.title,
            sourceTerms: (topic.associatedTags as? Set<ThoughtTag>)?.map(\.name).sorted() ?? [],
            removedThoughtCount: (topic.thoughts as? Set<Thought>)?.count ?? 0
        )

        // 显式断开关系（delete rule 均为 nullify 会自动处理，显式断开更稳，与 deleteTagGlobally 同风格）
        if let thoughts = topic.thoughts as? Set<Thought> {
            topic.removeThoughts(thoughts)
        }
        if let tags = topic.associatedTags as? Set<ThoughtTag> {
            topic.removeAssociatedTags(tags)
        }
        // 自引用：被合并进本主题的子主题指向断开，避免悬挂
        if let mergedFrom = topic.mergedFromTopics as? Set<Topic> {
            for child in mergedFrom {
                child.mergedToTopic = nil
            }
        }
        topic.mergedToTopic = nil

        context.delete(topic)
        try context.save()
        return result
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

    // MARK: - 按 Topic 查观点（P1.5.2）

    /// 查某 Topic 下观点（走 Thought.topics 关系）
    /// - Parameter includeArchived: 是否包含已归档（默认不包含）
    func fetchThoughts(byTopic topicId: UUID, includeArchived: Bool = false) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let topicPredicate = NSPredicate(format: "ANY topics.id == %@", topicId as CVarArg)
        let deletePredicate = includeArchived
            ? NSPredicate(format: "isSoftDeleted == NO")
            : NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [topicPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 在某 Topic 范围内搜索
    func searchWithinTopic(topicId: UUID, query: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let topicPredicate = NSPredicate(format: "ANY topics.id == %@", topicId as CVarArg)
        let searchPredicate = NSPredicate(format: "content CONTAINS[cd] %@", query)
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [topicPredicate, searchPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    // MARK: - 手动移入/移出（P1.5.6）

    enum AssignError: Error {
        case thoughtNotFound
        case topicNotFound
    }

    /// 把观点移入主题（手动标签 manual/inline 不动，spec 决策）
    func assign(thoughtId: UUID, toTopic topicId: UUID) throws {
        guard let thought = try fetchThoughtById(thoughtId) else { throw AssignError.thoughtNotFound }
        guard let topic = try fetchTopicById(topicId) else { throw AssignError.topicNotFound }
        topic.addThoughts(thought)
        topic.updatedAt = Date()
        try context.save()
    }

    /// 把观点移出主题
    func remove(thoughtId: UUID, fromTopic topicId: UUID) throws {
        guard let thought = try fetchThoughtById(thoughtId) else { throw AssignError.thoughtNotFound }
        guard let topic = try fetchTopicById(topicId) else { throw AssignError.topicNotFound }
        topic.removeThoughts(thought)
        topic.updatedAt = Date()
        try context.save()
    }

    // MARK: - 应用归并建议（P2.4，归并不改 source，spec §6.3）

    /// 应用跨观点归并：get-or-create Topic + 来源词写主源 + 观点关联（source 保持 .ai 不变）
    /// - Parameters:
    ///   - matchedTopicId: 归入现有主题 id；nil 则按 topicTitle 新建并激活
    ///   - topicTitle: 主题名（新建或归入校验用）
    ///   - thoughtIds: 被归并的观点 id 列表
    ///   - sourceTerms: 来源词（写入 associatedTags 主源）
    /// - Returns: 目标 Topic
    @discardableResult
    func applyConvergence(
        matchedTopicId: UUID?,
        topicTitle: String,
        thoughtIds: [UUID],
        sourceTerms: [String]
    ) throws -> Topic {
        let topic: Topic
        if let matchedId = matchedTopicId, let existing = try fetchTopicById(matchedId) {
            topic = existing
        } else {
            topic = try getOrCreateTopic(title: topicTitle)
            try activate(topic)
        }
        if !sourceTerms.isEmpty {
            try setSourceTerms(topic: topic, tagNames: sourceTerms)
        }
        // 观点关联 Topic（Thought.topics）；assignment source 保持 .ai 不变（spec 决策 4）
        for thoughtId in thoughtIds {
            try? assign(thoughtId: thoughtId, toTopic: topic.id)
        }
        return topic
    }

    private func fetchThoughtById(_ id: UUID) throws -> Thought? {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func fetchTopicById(_ id: UUID) throws -> Topic? {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
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
        for name in tagNames {
            let displayName = ThoughtTagNormalizer.displayName(name)
            guard !displayName.isEmpty else { continue }
            resolved.append(try getOrCreateTag(name: displayName))
        }
        topic.addAssociatedTags(Set(resolved))
        topic.refreshAssociatedTagNamesCache()
        topic.updatedAt = Date()
        try context.save()
    }

    /// get-or-create ThoughtTag（P1.5.3 提权 ThoughtRepository.getOrCreateTag 后可复用，此处本地实现）
    private func getOrCreateTag(name: String) throws -> ThoughtTag {
        let displayName = ThoughtTagNormalizer.displayName(name)
        let key = ThoughtTagNormalizer.key(displayName)
        let request = ThoughtTag.fetchRequest()
        let tags = try context.fetch(request)
        if let existing = tags.first(where: { ThoughtTagNormalizer.key($0.name) == key }) {
            if existing.name != displayName, !displayName.isEmpty {
                existing.name = displayName
            }
            return existing
        }
        let tag = ThoughtTag(context: context)
        tag.id = UUID()
        tag.name = displayName
        tag.usageCount = 0
        return tag
    }
}

// MARK: - 删除结果

/// 主题删除结果（供 UI 反馈与归并拒绝记录）
struct TopicDeletionResult {
    /// 被删主题名
    let title: String
    /// 来源词集合（排序后，供 ConvergenceRejectionRepository.reject 使用）
    let sourceTerms: [String]
    /// 摘除的想法关联数（供 toast 反馈）
    let removedThoughtCount: Int
}
