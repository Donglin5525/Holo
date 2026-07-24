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

    private static let visibleStatusValues = [
        Topic.TopicStatus.active.rawValue,
        Topic.TopicStatus.candidate.rawValue,
        Topic.TopicStatus.classification.rawValue
    ]

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
        guard let topic = NSEntityDescription.insertNewObject(
            forEntityName: "Topic",
            into: context
        ) as? Topic else {
            throw NSError(
                domain: "TopicRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 Topic 实体"]
            )
        }
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

    /// 按标题归一化查询（所有可见状态，排除 hidden / merged）
    func getByTitle(_ title: String) throws -> Topic? {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            Self.visibleStatusValues
        )
        let topics = try context.fetch(request)
        let key = Self.normalizedKey(title: title)
        return topics.first { Self.normalizedKey(title: $0.title) == key }
    }

    /// 所有可展示主题（含用户启用的 classification），按 thoughtCount 降序
    func fetchVisibleTopics() throws -> [Topic] {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(format: "status IN %@", Self.visibleStatusValues)
        let topics = try context.fetch(request)
        return topics.sorted { thoughtCount(of: $0) > thoughtCount(of: $1) }
    }

    /// 用户明确启用、允许进入 AI 单选约束池的主题。
    func fetchClassificationTopics() throws -> [Topic] {
        let request = Topic.fetchRequest()
        request.predicate = NSPredicate(
            format: "status == %@",
            Topic.TopicStatus.classification.rawValue
        )
        let topics = try context.fetch(request)
        return topics.sorted {
            if thoughtCount(of: $0) == thoughtCount(of: $1) { return $0.title < $1.title }
            return thoughtCount(of: $0) > thoughtCount(of: $1)
        }
    }

    // MARK: - 更新 / 状态

    func updateTitle(_ topic: Topic, title: String) throws {
        topic.title = title
        topic.updatedAt = Date()
        try context.save()
    }

    /// 新建或复用一个主题，并明确启用为 AI 分类约束。
    @discardableResult
    func createClassificationTopic(title: String) throws -> Topic {
        let normalizedTitle = ThoughtTagNormalizer.displayName(title)
        guard !normalizedTitle.isEmpty,
              TopicRepository.normalizedKey(title: normalizedTitle) != ThoughtTagNormalizer.key(ThoughtThemeConstraint.unclassifiedTitle)
        else { throw ThoughtError.tagNameEmpty }

        let topic = try getOrCreateTopic(title: normalizedTitle)
        topic.status = Topic.TopicStatus.classification.rawValue
        topic.updatedAt = Date()
        try context.save()
        return topic
    }

    /// Onboarding 批量初始化；逐个幂等复用，最终一次返回真实 Topic。
    func createClassificationTopics(titles: [String]) throws -> [Topic] {
        var topics: [Topic] = []
        var seen: Set<String> = []
        for title in titles {
            let displayTitle = ThoughtTagNormalizer.displayName(title)
            let key = Self.normalizedKey(title: displayTitle)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            topics.append(try createClassificationTopic(title: displayTitle))
        }
        return topics
    }

    /// 老用户可显式把历史 Topic 纳入或移出 AI 分类约束池。
    func setClassificationEnabled(_ topic: Topic, isEnabled: Bool) throws {
        if isEnabled,
           Self.normalizedKey(title: topic.title) == ThoughtTagNormalizer.key(ThoughtThemeConstraint.unclassifiedTitle) {
            throw ThoughtError.tagNameEmpty
        }
        topic.status = isEnabled
            ? Topic.TopicStatus.classification.rawValue
            : Topic.TopicStatus.active.rawValue
        if isEnabled {
            // 历史数据可能一条想法关联多个旧 Topic；显式启用时以本次主题为准，恢复单选契约。
            for thought in (topic.thoughts as? Set<Thought>) ?? [] {
                for other in (thought.topics as? Set<Topic>) ?? []
                where other.id != topic.id && other.isClassificationTopic {
                    other.removeThoughts(thought)
                    other.updatedAt = Date()
                }
            }
        }
        topic.updatedAt = Date()
        try context.save()
    }

    /// 分类主题改名：同步 Topic 标题与已有 `主题/子标签` 路径。
    func renameClassificationTopic(_ topic: Topic, to newTitle: String) throws {
        let normalizedTitle = ThoughtTagNormalizer.displayName(newTitle)
        guard !normalizedTitle.isEmpty,
              Self.normalizedKey(title: normalizedTitle) != ThoughtTagNormalizer.key(ThoughtThemeConstraint.unclassifiedTitle)
        else { throw ThoughtError.tagNameEmpty }
        if let existing = try getByTitle(normalizedTitle), existing.id != topic.id {
            throw ThoughtError.tagInUse
        }
        let oldTitle = topic.title
        if try hasTagPathPrefix(oldTitle) {
            _ = try ThoughtRepository(context: context).renameTagPathPrefix(from: oldTitle, to: normalizedTitle)
        }
        topic.title = normalizedTitle
        topic.updatedAt = Date()
        topic.refreshAssociatedTagNamesCache()
        try context.save()
    }

    /// 分类主题合并：标签路径、想法关系和来源词均迁移到保留主题。
    func mergeClassificationTopics(into keeper: Topic, from duplicate: Topic) throws {
        guard keeper != duplicate else { return }
        if try hasTagPathPrefix(duplicate.title) {
            _ = try ThoughtRepository(context: context).renameTagPathPrefix(from: duplicate.title, to: keeper.title)
        }
        keeper.status = Topic.TopicStatus.classification.rawValue
        try merge(into: keeper, from: duplicate)
        keeper.refreshAssociatedTagNamesCache()
        try context.save()
    }

    /// 删除分类主题：先把路径降级为“未分类/”，再删除 Topic 关系。
    @discardableResult
    func deleteClassificationTopic(_ topic: Topic) throws -> TopicDeletionResult {
        if try hasTagPathPrefix(topic.title) {
            _ = try ThoughtRepository(context: context).renameTagPathPrefix(
                from: topic.title,
                to: ThoughtThemeConstraint.unclassifiedTitle
            )
        }
        return try delete(topic)
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
        // 同步去重时不能因为抓取顺序丢掉用户已启用的 classification 状态。
        if keeper.isClassificationTopic || duplicate.isClassificationTopic {
            keeper.status = Topic.TopicStatus.classification.rawValue
        } else if keeper.statusEnum == .candidate && duplicate.statusEnum == .active {
            keeper.status = Topic.TopicStatus.active.rawValue
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
            Self.visibleStatusValues
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
        if topic.isClassificationTopic {
            for existing in (thought.topics as? Set<Topic>) ?? []
            where existing.isClassificationTopic && existing.id != topic.id {
                existing.removeThoughts(thought)
                existing.updatedAt = Date()
            }
        }
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

    /// 写入一次 AI 分类结果。
    /// 只替换旧 classification Topic，历史/手动 Topic 关系保持不动；nil 表示进入虚拟“未归类”。
    func applyClassification(
        thoughtId: UUID,
        topicTitle: String?,
        tagPaths: [String]
    ) throws {
        guard let thought = try fetchThoughtById(thoughtId) else { throw AssignError.thoughtNotFound }

        for oldTopic in (thought.topics as? Set<Topic>) ?? [] where oldTopic.isClassificationTopic {
            oldTopic.removeThoughts(thought)
            oldTopic.updatedAt = Date()
        }

        guard let topicTitle,
              let topic = try fetchClassificationTopics().first(where: {
                  Self.normalizedKey(title: $0.title) == Self.normalizedKey(title: topicTitle)
              }) else {
            try context.save()
            return
        }

        topic.addThoughts(thought)
        for path in tagPaths where ThoughtThemeConstraint.isTag(path, underTopic: topic.title) {
            topic.addAssociatedTags(try getOrCreateTag(name: path))
        }
        topic.refreshAssociatedTagNamesCache()
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
            topic = try createClassificationTopic(title: topicTitle)
        }
        // 用户确认建议即代表接受其作为后续分类边界；历史 matched Topic 也在此升级。
        topic.status = Topic.TopicStatus.classification.rawValue
        if !sourceTerms.isEmpty {
            try addSourceTerms(topic: topic, tagNames: sourceTerms)
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

    private func hasTagPathPrefix(_ prefix: String) throws -> Bool {
        let prefixKey = ThoughtTagNormalizer.key(prefix)
        let request = ThoughtTag.fetchRequest()
        return try context.fetch(request).contains { tag in
            let key = ThoughtTagNormalizer.key(tag.name)
            return key == prefixKey || key.hasPrefix(prefixKey + "/")
        }
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

    /// 增量补充归纳来源词，不清空分类过程中已关联的 `主题/子标签`。
    func addSourceTerms(topic: Topic, tagNames: [String]) throws {
        let existingNames = (topic.associatedTags as? Set<ThoughtTag>)?.map(\.name) ?? []
        try setSourceTerms(topic: topic, tagNames: existingNames + tagNames)
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
        guard let tag = NSEntityDescription.insertNewObject(
            forEntityName: "ThoughtTag",
            into: context
        ) as? ThoughtTag else {
            throw NSError(
                domain: "TopicRepository",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 ThoughtTag 实体"]
            )
        }
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
