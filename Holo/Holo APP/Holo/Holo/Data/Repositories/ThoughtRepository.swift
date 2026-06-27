//
//  ThoughtRepository.swift
//  Holo
//
//  观点模块 - 数据仓储层
//  负责 Thought 实体的增删改查操作
//

import Foundation
import CoreData
import os.log

// MARK: - Notification Names

extension Notification.Name {
    /// 观点数据变更通知（新增/编辑/删除想法时发送）
    static let thoughtDataDidChange = Notification.Name("thoughtDataDidChange")
}

/// 观点数据仓储
class ThoughtRepository {

    // MARK: - Properties

    private(set) var context: NSManagedObjectContext
    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtRepository")

    // MARK: - UserDefaults Keys

    private static let backfillFlagKey = "hasBackfilledTagAssignments"

    // MARK: - Initialization

    /// 初始化方法
    /// - Parameter context: NSManagedObjectContext，默认使用主上下文
    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
    }

    // MARK: - Fetch Operations

    /// 获取所有想法
    /// - Parameters:
    ///   - limit: 数量限制，nil 表示无限制
    ///   - offset: 偏移量
    ///   - sortBy: 排序方式
    /// - Returns: Thought 数组
    func fetchAll(
        limit: Int? = nil,
        offset: Int = 0,
        sortBy: ThoughtSortOption = .createdAtDescending
    ) throws -> [Thought] {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")

        // 设置排序
        switch sortBy {
        case .createdAtDescending:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        case .createdAtAscending:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        case .updatedAtDescending:
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        case .mood:
            request.sortDescriptors = [NSSortDescriptor(key: "mood", ascending: true)]
        }

        // 设置分页
        if let limit = limit {
            request.fetchLimit = limit
        }
        request.fetchOffset = offset

        return try context.fetch(request)
    }

    /// 根据 ID 获取想法
    /// - Parameter id: UUID
    /// - Returns: Thought 对象，不存在返回 nil
    func fetchById(_ id: UUID) throws -> Thought? {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO AND isArchived == NO", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// 根据 ID 获取想法（不过滤软删除/归档，用于内部操作）
    func fetchByIdInternal(_ id: UUID) throws -> Thought? {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// 根据标签获取想法
    /// - Parameter tagName: 标签名称
    /// - Returns: Thought 数组
    func fetchByTag(_ tagName: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let tagPredicate = NSPredicate(format: "ANY tags.name == %@", tagName)
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [tagPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 根据心情获取想法
    /// - Parameter mood: 心情类型
    /// - Returns: Thought 数组
    func fetchByMood(_ mood: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let moodPredicate = NSPredicate(format: "mood == %@", mood)
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [moodPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 搜索想法
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - filters: 筛选条件
    /// - Returns: Thought 数组
    func search(query: String, filters: ThoughtFilters? = nil) throws -> [Thought] {
        let request = Thought.fetchRequest()
        var predicates: [NSPredicate] = [NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")]

        // 搜索内容或标签
        if !query.isEmpty {
            let contentPredicate = NSPredicate(format: "content CONTAINS[cd] %@", query)
            let tagPredicate = NSPredicate(format: "ANY tags.name CONTAINS[cd] %@", query)
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [contentPredicate, tagPredicate]))
        }

        // 心情筛选
        if let mood = filters?.mood {
            predicates.append(NSPredicate(format: "mood == %@", mood))
        }

        // 日期范围筛选
        if let startDate = filters?.startDate {
            predicates.append(NSPredicate(format: "createdAt >= %@", startDate as CVarArg))
        }
        if let endDate = filters?.endDate {
            predicates.append(NSPredicate(format: "createdAt <= %@", endDate as CVarArg))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        return try context.fetch(request)
    }

    // MARK: - Create Operations

    /// 创建新想法（支持双写：同时写 Thought.tags 和 ThoughtTagAssignment）
    /// - Parameters:
    ///   - content: 内容
    ///   - mood: 心情
    ///   - manualTags: 手动选择的标签
    ///   - inlineTags: 正文内 #标签 自动提取的标签
    ///   - imageData: 图片数据
    /// - Returns: 创建的 Thought 对象
    @discardableResult
    func create(
        content: String,
        mood: String? = nil,
        manualTags: [String] = [],
        inlineTags: [String] = [],
        imageData: Data? = nil
    ) throws -> Thought {
        let thought = Thought(context: context)
        thought.id = UUID()
        thought.content = content
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.mood = mood
        thought.orderIndex = 0
        thought.imageData = imageData
        thought.isSoftDeleted = false
        thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId

        // 初始化 organizedStatus
        let autoOrgEnabled = UserDefaults.standard.bool(forKey: Self.autoOrganizationEnabledKey)
        // 首次读取时如果 key 不存在，默认为开启
        let isEnabled = UserDefaults.standard.object(forKey: Self.autoOrganizationEnabledKey) as? Bool ?? true

        if !isEnabled {
            thought.organizedStatus = "disabled"
        } else if content.count < 10 {
            thought.organizedStatus = "skipped"
        } else {
            thought.organizedStatus = "pending"
        }

        // 合并去重标签
        let allTagNames = Array(Set(manualTags + inlineTags))

        // 双写：同时写 Thought.tags（旧 UI 兼容）和 ThoughtTagAssignment（新数据源）
        for tagName in manualTags {
            let tag = try getOrCreateTag(name: tagName)
            thought.addTags(tag)
            createAssignmentInternal(thought: thought, tag: tag, source: .manual, confidence: 1.0)
        }

        for tagName in inlineTags {
            // 去重：如果 manualTags 已包含该标签，不再重复创建 assignment
            guard !manualTags.contains(tagName) else { continue }
            let tag = try getOrCreateTag(name: tagName)
            thought.addTags(tag)
            createAssignmentInternal(thought: thought, tag: tag, source: .inline, confidence: 1.0)
        }

        try context.save()
        return thought
    }

    /// 兼容旧调用方：合并标签后创建
    @discardableResult
    func create(
        content: String,
        mood: String? = nil,
        tags: [String] = [],
        imageData: Data? = nil
    ) throws -> Thought {
        try create(
            content: content,
            mood: mood,
            manualTags: tags,
            inlineTags: [],
            imageData: imageData
        )
    }

    // MARK: - Update Operations

    /// 更新想法（支持双写）
    /// - Parameters:
    ///   - id: 想法 ID
    ///   - content: 新内容
    ///   - mood: 新心情
    ///   - tags: 新标签数组（合并后的，视为 manual）
    /// - Returns: 更新后的 Thought 对象
    @discardableResult
    func update(
        _ id: UUID,
        content: String? = nil,
        mood: String? = nil,
        tags: [String]? = nil
    ) throws -> Thought {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        if let content = content {
            thought.content = content
        }
        if let mood = mood {
            thought.mood = mood
        }

        thought.updatedAt = Date()

        // 更新标签（双写）
        if let tags = tags {
            // 清除旧 Thought.tags 关联
            thought.tags?.forEach { tag in
                if let tag = tag as? ThoughtTag {
                    thought.removeTags(tag)
                }
            }

            // 添加新标签（双写）
            for tagName in tags {
                let tag = try getOrCreateTag(name: tagName)
                thought.addTags(tag)
                createAssignmentInternal(thought: thought, tag: tag, source: .manual, confidence: 1.0)
            }
        }

        try context.save()
        return thought
    }

    // MARK: - Delete Operations

    /// 删除想法（软删除）
    /// - Parameter id: 想法 ID
    func delete(_ id: UUID) throws {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        // 软删除：只标记 isSoftDeleted，不断开引用关系
        thought.isSoftDeleted = true
        thought.updatedAt = Date()

        try context.save()
    }

    /// 硬删除想法（用于彻底删除）
    /// - Parameter id: 想法 ID
    func hardDelete(_ id: UUID) throws {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        // 清理附件文件（Core Data 级联删除前先清理磁盘）
        deleteAllAttachmentFiles(for: thought)

        // 删除相关的引用关系
        if let references = thought.references as? Set<ThoughtReference> {
            references.forEach { context.delete($0) }
        }
        if let referencedBy = thought.referencedBy as? Set<ThoughtReference> {
            referencedBy.forEach { context.delete($0) }
        }

        // ThoughtTagAssignment 通过 cascade delete rule 自动级联删除
        // ThoughtAttachment 通过 cascade delete rule 自动级联删除
        // Topic 多对多关系通过 nullify 自动断开

        context.delete(thought)
        try context.save()
    }

    // MARK: - Archive Operations

    /// 归档想法
    /// - Parameter id: 想法 ID
    func archive(_ id: UUID) throws {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO", id as CVarArg)
        request.fetchLimit = 1

        guard let thought = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        thought.isArchived = true
        thought.updatedAt = Date()

        try context.save()
    }

    /// 取消归档想法
    /// - Parameter id: 想法 ID
    func unarchive(_ id: UUID) throws {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO", id as CVarArg)
        request.fetchLimit = 1

        guard let thought = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        thought.isArchived = false
        thought.updatedAt = Date()

        try context.save()
    }

    /// 获取已归档的想法
    /// - Returns: Thought 数组
    func fetchArchived() throws -> [Thought] {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request)
    }

    // MARK: - Reference Operations

    /// 添加引用关系
    /// - Parameters:
    ///   - sourceId: 引用发起方 ID
    ///   - targetId: 被引用方 ID
    func addReference(sourceId: UUID, targetId: UUID) throws {
        guard let source = try fetchById(sourceId),
              let target = try fetchById(targetId) else {
            throw ThoughtError.notFound
        }

        let reference = ThoughtReference(context: context)
        reference.id = UUID()
        reference.createdAt = Date()
        reference.sourceThought = source
        reference.targetThought = target

        try context.save()
    }

    /// 移除引用关系
    /// - Parameters:
    ///   - sourceId: 引用发起方 ID
    ///   - targetId: 被引用方 ID
    func removeReference(sourceId: UUID, targetId: UUID) throws {
        let request = ThoughtReference.fetchRequest()
        let sourcePredicate = NSPredicate(format: "sourceThought.id == %@", sourceId as CVarArg)
        let targetPredicate = NSPredicate(format: "targetThought.id == %@", targetId as CVarArg)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, targetPredicate])

        guard let reference = try context.fetch(request).first else {
            return
        }

        context.delete(reference)
        try context.save()
    }

    /// 获取想法引用的其他想法
    /// - Parameter id: 想法 ID
    /// - Returns: Thought 数组
    func getReferences(for id: UUID) throws -> [Thought] {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        return (thought.references as? Set<ThoughtReference>)?
            .compactMap { $0.targetThought }
            .filter { !$0.isSoftDeleted } ?? []
    }

    /// 获取引用该想法的其他想法
    /// - Parameter id: 想法 ID
    /// - Returns: Thought 数组
    func getReferencedBy(id: UUID) throws -> [Thought] {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        return (thought.referencedBy as? Set<ThoughtReference>)?
            .compactMap { $0.sourceThought }
            .filter { !$0.isSoftDeleted } ?? []
    }

    // MARK: - Tag Operations

    /// 获取所有标签
    /// - Returns: ThoughtTag 数组
    func getAllTags() throws -> [ThoughtTag] {
        let request = ThoughtTag.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "usageCount", ascending: false)]
        return try context.fetch(request)
    }

    /// 获取或创建标签
    /// - Parameter name: 标签名称
    /// - Returns: ThoughtTag 对象
    private func getOrCreateTag(name: String) throws -> ThoughtTag {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", name)

        if let tag = try context.fetch(request).first {
            // 增加使用次数
            tag.usageCount += 1
            return tag
        } else {
            let tag = ThoughtTag(context: context)
            tag.id = UUID()
            tag.name = name
            tag.usageCount = 1
            return tag
        }
    }

    /// 合并标签
    /// - Parameters:
    ///   - oldName: 原标签名
    ///   - newName: 新标签名
    func mergeTags(oldName: String, newName: String) throws {
        let oldTags = try getOrCreateTag(name: oldName)
        let newTag = try getOrCreateTag(name: newName)

        // 将旧标签关联的想法转移到新标签
        if let thoughts = oldTags.thoughts as? Set<Thought> {
            for thought in thoughts {
                oldTags.removeThoughts(thought)
                newTag.addThoughts(thought)
            }
        }

        // 删除旧标签
        context.delete(oldTags)
        try context.save()
    }

    /// 清除所有观点数据（Thought + ThoughtTag + ThoughtReference + ThoughtTagAssignment + Topic + ThoughtAttachment）
    func deleteAllThoughtData() throws {
        // 先清理所有想法的附件文件
        let thoughtRequest = Thought.fetchRequest()
        if let allThoughts = try? context.fetch(thoughtRequest) {
            for thought in allThoughts {
                deleteAllAttachmentFiles(for: thought)
            }
        }

        let entities = ["ThoughtAttachment", "ThoughtReference", "ThoughtTagAssignment", "Topic", "Thought", "ThoughtTag"]
        for entity in entities {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            let objects = try context.fetch(request)
            for obj in objects {
                context.delete(obj)
            }
        }
        try context.save()
    }

    /// 删除未使用的标签
    /// - Parameter name: 标签名称
    func deleteTag(_ name: String) throws {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", name)

        guard let tag = try context.fetch(request).first else {
            return
        }

        // 检查是否有思想使用该标签
        if let thoughts = tag.thoughts as? Set<Thought>, !thoughts.isEmpty {
            throw ThoughtError.tagInUse
        }

        context.delete(tag)
        try context.save()
    }

    // MARK: - ThoughtTagAssignment Operations

    /// 为想法创建标签分配
    /// - Parameters:
    ///   - thoughtId: 想法 ID
    ///   - tagName: 标签名称
    ///   - source: 标签来源
    ///   - confidence: 置信度
    func createTagAssignment(
        thoughtId: UUID,
        tagName: String,
        source: ThoughtTagAssignment.Source,
        confidence: Double
    ) throws {
        guard let thought = try fetchByIdInternal(thoughtId) else {
            throw ThoughtError.notFound
        }
        let tag = try getOrCreateTag(name: tagName)
        createAssignmentInternal(thought: thought, tag: tag, source: source, confidence: confidence)
        try context.save()
    }

    /// 获取想法的标签分配
    /// - Parameters:
    ///   - thoughtId: 想法 ID
    ///   - sourceFilter: 可选的来源过滤
    /// - Returns: ThoughtTagAssignment 数组
    func fetchAssignments(
        thoughtId: UUID,
        sourceFilter: [ThoughtTagAssignment.Source]? = nil
    ) throws -> [ThoughtTagAssignment] {
        guard let thought = try fetchByIdInternal(thoughtId) else {
            throw ThoughtError.notFound
        }

        guard let assignments = thought.tagAssignments as? Set<ThoughtTagAssignment> else {
            return []
        }

        var result = Array(assignments)

        if let sourceFilter = sourceFilter {
            let sourceValues = sourceFilter.map { $0.rawValue }
            result = result.filter { sourceValues.contains($0.source) }
        }

        return result.sorted { $0.assignedAt > $1.assignedAt }
    }

    /// 获取想法的可展示 AI 标签分配（source == ai 或 confirmedAI，排除 rejectedAI）
    /// - Parameter thoughtId: 想法 ID
    /// - Returns: ThoughtTagAssignment 数组
    func fetchVisibleAIAssignments(thoughtId: UUID) throws -> [ThoughtTagAssignment] {
        try fetchAssignments(
            thoughtId: thoughtId,
            sourceFilter: [.ai, .confirmedAI]
        )
    }

    // MARK: - AI 标签池聚合（知识树抽屉）

    /// AI 标签池聚合桶（按 tagName 分组）
    struct AITagBucket: Identifiable {
        /// 用 tagName 作唯一标识
        var id: String { tagName }
        /// 标签名
        let tagName: String
        /// 命中该标签的 .ai/.confirmedAI assignment 数
        let assignmentCount: Int
        /// 按来源拆分，key 为 Source.rawValue（"ai" / "confirmedAI"）
        let sourceBreakdown: [String: Int]
    }

    /// 聚合 AI 标签池：按 source ∈ [.ai, .confirmedAI] 且 rejectedAt == nil 的 assignment 聚合
    /// - Parameter excludeAbsorbed: true 时排除已被 Topic 收纳的 assignment（Thought+Tag+Topic 三者交集，P1.5.4 接入）
    /// - Returns: 按 tagName 分组的桶（assignmentCount 降序，同 count 按 name 升序）
    /// - Note: 走 ThoughtTagAssignment，不走 Thought.tags（spec §10-3 数据源割裂）
    func fetchAITagBuckets(excludeAbsorbed: Bool = false) throws -> [AITagBucket] {
        let request = ThoughtTagAssignment.fetchRequest()
        let sourcePredicate = NSPredicate(
            format: "source IN %@",
            [ThoughtTagAssignment.Source.ai.rawValue, ThoughtTagAssignment.Source.confirmedAI.rawValue]
        )
        let notRejectedPredicate = NSPredicate(format: "rejectedAt == nil")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, notRejectedPredicate])

        let assignments = try context.fetch(request)

        // P1.5.4: excludeAbsorbed == true 时排除已被 Topic 收纳的 assignment（Thought+Tag+Topic 三者交集）
        let effectiveAssignments: [ThoughtTagAssignment]
        if excludeAbsorbed {
            let service = TopicService()
            effectiveAssignments = assignments.filter { !service.isAbsorbed($0) }
        } else {
            effectiveAssignments = assignments
        }

        // 按 tag.name 分组计数 + 来源拆分
        var groups: [String: (count: Int, breakdown: [String: Int])] = [:]
        for assignment in effectiveAssignments {
            guard let tag = assignment.tag else { continue }
            let tagName = tag.name
            guard !tagName.isEmpty else { continue }
            var group = groups[tagName] ?? (count: 0, breakdown: [:])
            group.count += 1
            group.breakdown[assignment.source, default: 0] += 1
            groups[tagName] = group
        }

        return groups.map { tagName, value in
            AITagBucket(tagName: tagName, assignmentCount: value.count, sourceBreakdown: value.breakdown)
        }
        .sorted { lhs, rhs in
            lhs.assignmentCount != rhs.assignmentCount
                ? lhs.assignmentCount > rhs.assignmentCount
                : lhs.tagName < rhs.tagName
        }
    }

    /// 按 AI 标签筛选观点：命中该 tag 的 .ai/.confirmedAI assignment 的观点
    /// 走 ThoughtTagAssignment（SUBQUERY 保证 name+source 同一 assignment），不走 Thought.tags（spec §10-3）
    /// - Parameter tagName: AI 标签名
    func fetchThoughtsByAITag(_ tagName: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let aiSources = [
            ThoughtTagAssignment.Source.ai.rawValue,
            ThoughtTagAssignment.Source.confirmedAI.rawValue
        ]
        let assignmentPredicate = NSPredicate(
            format: "SUBQUERY(tagAssignments, $a, $a.tag.name == %@ AND $a.source IN %@ AND $a.rejectedAt == nil).@count > 0",
            tagName, aiSources
        )
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [assignmentPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 未归类观点：未进入任何 Topic（topics 关系为空）
    /// P1 Topic 表空 → 等价全部 active；P1.5 有 Topic 后仅返回真正未归类的
    func fetchUnclassifiedThoughts() throws -> [Thought] {
        let request = Thought.fetchRequest()
        let unclassifiedPredicate = NSPredicate(format: "topics.@count == 0")
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [unclassifiedPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    // MARK: - 跨观点收敛候选（P2.2，thought_tag_convergence 输入收集）

    /// 收敛候选观点（带 .ai/.confirmedAI 标签，供 thought_tag_convergence 调用）
    struct ConvergenceCandidate: Identifiable {
        /// thought id
        let id: UUID
        /// 观点内容（原文，调用前由 Job 截断）
        let summary: String
        /// 该观点的 .ai/.confirmedAI 标签名
        let tags: [String]
    }

    /// 取参与跨观点收敛的候选观点：带未拒绝的 .ai/.confirmedAI 标签、未 softDeleted/archived
    /// - Parameter maxCount: 最多取多少条（控制 prompt 体积）
    /// - Note: 走 ThoughtTagAssignment（SUBQUERY 保证 source+rejectedAt 同一 assignment），不走 Thought.tags
    func fetchConvergenceCandidates(maxCount: Int = 50) throws -> [ConvergenceCandidate] {
        let request = Thought.fetchRequest()
        let aiSources = [
            ThoughtTagAssignment.Source.ai.rawValue,
            ThoughtTagAssignment.Source.confirmedAI.rawValue
        ]
        let assignmentPredicate = NSPredicate(
            format: "SUBQUERY(tagAssignments, $a, $a.source IN %@ AND $a.rejectedAt == nil).@count > 0",
            aiSources
        )
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [assignmentPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = maxCount

        let thoughts = try context.fetch(request)
        return thoughts.compactMap { thought in
            let assignments = thought.tagAssignments as? Set<ThoughtTagAssignment> ?? []
            let tags = assignments
                .filter { assignment in
                    let src = assignment.source
                    return (src == ThoughtTagAssignment.Source.ai.rawValue
                            || src == ThoughtTagAssignment.Source.confirmedAI.rawValue)
                        && assignment.rejectedAt == nil
                }
                .compactMap { $0.tag?.name }
                .filter { !$0.isEmpty }
            guard !tags.isEmpty else { return nil }
            return ConvergenceCandidate(id: thought.id, summary: thought.content, tags: tags)
        }
    }

    /// 拒绝（删除）AI 标签：将 source 改为 rejectedAI
    /// - Parameter assignmentId: 分配 ID
    func rejectTagAssignment(assignmentId: UUID) throws {
        let request = ThoughtTagAssignment.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", assignmentId as CVarArg)
        request.fetchLimit = 1

        guard let assignment = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        assignment.source = ThoughtTagAssignment.Source.rejectedAI.rawValue
        assignment.rejectedAt = Date()

        try context.save()
    }

    /// 确认 AI 标签：将 source 从 ai 改为 confirmedAI
    /// - Parameter assignmentId: 分配 ID
    func confirmTagAssignment(assignmentId: UUID) throws {
        let request = ThoughtTagAssignment.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", assignmentId as CVarArg)
        request.fetchLimit = 1

        guard let assignment = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        assignment.source = ThoughtTagAssignment.Source.confirmedAI.rawValue

        try context.save()
    }

    // MARK: - Backfill

    /// 首次启动时将旧 Thought.tags 关系转为 ThoughtTagAssignment
    /// 只执行一次（UserDefaults flag 控制）
    func backfillTagAssignmentsIfNeeded() {
        let flagKey = Self.backfillFlagKey
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        logger.info("开始 backfill ThoughtTagAssignment...")

        do {
            let request = Thought.fetchRequest()
            // 包括软删除/归档的，确保数据完整
            let allThoughts = try context.fetch(request)
            var totalAssignments = 0

            for thought in allThoughts {
                guard let tags = thought.tags as? Set<ThoughtTag> else { continue }

                for tag in tags {
                    createAssignmentInternal(
                        thought: thought,
                        tag: tag,
                        source: .manual,
                        confidence: 1.0
                    )
                    totalAssignments += 1
                }

                // 所有旧想法标记为 unprocessed（不自动入队）
                thought.organizedStatus = "unprocessed"
            }

            try context.save()
            UserDefaults.standard.set(true, forKey: flagKey)
            logger.info("Backfill 完成：\(totalAssignments) 条 assignment，\(allThoughts.count) 条想法标记为 unprocessed")
        } catch {
            logger.error("Backfill 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Organization Status Operations

    /// 更新想法的整理状态
    /// - Parameters:
    ///   - thoughtId: 想法 ID
    ///   - status: 新状态
    func updateOrganizedStatus(thoughtId: UUID, status: String) throws {
        guard let thought = try fetchByIdInternal(thoughtId) else {
            throw ThoughtError.notFound
        }
        thought.organizedStatus = status

        // 进入 processing 时记录开始时间
        if status == "processing" {
            thought.organizationStartedAt = Date()
        }
        // 离开 processing 时清空开始时间
        if status != "processing" {
            thought.organizationStartedAt = nil
        }

        try context.save()
    }

    /// 恢复 processing 超时的想法（App 启动时调用）
    func recoverStaleProcessingThoughts() {
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)

        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(
            format: "organizedStatus == 'processing' AND organizationStartedAt < %@",
            fiveMinutesAgo as CVarArg
        )

        do {
            let staleThoughts = try context.fetch(request)
            for thought in staleThoughts {
                thought.organizedStatus = "pending"
                thought.organizationStartedAt = nil
                logger.info("恢复 processing 超时想法：\(thought.id)")
            }
            if !staleThoughts.isEmpty {
                try context.save()
            }
        } catch {
            logger.error("恢复 processing 超时想法失败：\(error.localizedDescription)")
        }
    }

    /// 获取待整理的想法队列（App 启动时重建队列）
    /// - Returns: 待整理的 thoughtId 列表（按 createdAt 升序）
    func fetchPendingThoughtIds() throws -> [UUID] {
        let currentDeviceId = HoloBackendDeviceIdentity.shared.deviceId

        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(
            format: "organizedStatus == 'pending' AND createdDeviceId == %@ AND isSoftDeleted == NO AND isArchived == NO",
            currentDeviceId as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        return try context.fetch(request).map { $0.id }
    }

    // MARK: - Batch Organization Operations

    /// 终态状态集合：这些状态的想法不再纳入「自动整理」批量范围
    /// 用「排除终态」写法，使 nil/空字符串等脏值也被纳入（安全方向）
    private static let terminalOrganizedStatuses = [
        "organized", "pending", "processing", "skipped", "disabled", "failed"
    ]

    /// 获取所有未整理的想法 ID（排除终态，含 nil/空字符串等脏值）
    /// 用于「自动整理」批量入口，按 createdAt 升序（老想法先整理）
    /// - Returns: 未整理的 thoughtId 列表
    func fetchUnprocessedThoughtIds() throws -> [UUID] {
        let request = Thought.fetchRequest()
        // 不按 createdDeviceId 过滤：批量整理是本地补标签操作，
        // 老想法（createdDeviceId 为 nil 或旧 deviceId）都应纳入；已 organized 的无论哪台设备都会被排除，不会重复
        request.predicate = NSPredicate(
            format: "NOT (organizedStatus IN %@) AND isSoftDeleted == NO AND isArchived == NO",
            Self.terminalOrganizedStatuses as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

        return try context.fetch(request).map { $0.id }
    }

    /// 统计未整理的想法数量（chip 徽章用，轻量 count 查询，不全量 fetch）
    /// - Returns: 未整理数量
    func countUnprocessed() throws -> Int {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(
            format: "NOT (organizedStatus IN %@) AND isSoftDeleted == NO AND isArchived == NO",
            Self.terminalOrganizedStatuses as CVarArg
        )

        return try context.count(for: request)
    }

    /// 批量将想法标记为 pending（供「自动整理」入队前调用）
    /// 使用普通 fetch + 改属性 + save，保证 viewContext 后续读一致（不用 NSBatchUpdateRequest）
    /// - Parameter thoughtIds: 待标记的想法 ID 列表
    func markBatchPending(thoughtIds: [UUID]) throws {
        guard !thoughtIds.isEmpty else { return }

        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", thoughtIds as CVarArg)
        request.fetchLimit = thoughtIds.count

        let thoughts = try context.fetch(request)
        for thought in thoughts {
            thought.organizedStatus = "pending"
            thought.organizationStartedAt = nil
        }
        try context.save()
        logger.info("批量标记 pending：\(thoughts.count)/\(thoughtIds.count) 条")
    }

    // MARK: - Aggregation

    /// 指定时间范围内的想法总数
    func getThoughtCount(from start: Date, to end: Date) -> Int {
        let request = Thought.fetchRequest()
        request.predicate = basePredicate(from: start, to: end)
        return (try? context.count(for: request)) ?? 0
    }

    /// 按天统计想法数量，返回 [yyyy-MM-dd: count]
    func getThoughtCountByDay(from start: Date, to end: Date) -> [String: Int] {
        let request = Thought.fetchRequest()
        request.predicate = basePredicate(from: start, to: end)

        guard let thoughts = try? context.fetch(request) else { return [:] }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var counts: [String: Int] = [:]
        for thought in thoughts {
            let key = dateFormatter.string(from: thought.createdAt)
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// 指定时间范围内的心情分布（跳过 mood 为 nil 的记录）
    func getMoodDistribution(from start: Date, to end: Date) -> [String: Int] {
        let request = Thought.fetchRequest()
        request.predicate = basePredicate(from: start, to: end)

        guard let thoughts = try? context.fetch(request) else {
            logger.error("获取心情分布失败")
            return [:]
        }

        var distribution: [String: Int] = [:]
        for thought in thoughts {
            guard let mood = thought.mood else { continue }
            distribution[mood, default: 0] += 1
        }
        return distribution
    }

    /// 指定时间范围内的热门标签（按关联想法数排序）
    /// v1a 继续读 thought.tags（双写保证数据一致）
    func getTopTags(from start: Date, to end: Date, limit: Int) -> [ThoughtTag] {
        let request = Thought.fetchRequest()
        request.predicate = basePredicate(from: start, to: end)

        guard let thoughts = try? context.fetch(request), !thoughts.isEmpty else { return [] }

        var tagCounts: [ThoughtTag: Int] = [:]
        for thought in thoughts {
            guard let tags = thought.tags as? Set<ThoughtTag> else { continue }
            for tag in tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        return tagCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    /// 指定时间范围内的想法原文截取（每篇 ≤200 字，按创建时间倒序）
    func getThoughtTexts(from start: Date, to end: Date, limit: Int) -> [String] {
        let request = Thought.fetchRequest()
        let datePredicate = basePredicate(from: start, to: end)
        let contentPredicate = NSPredicate(format: "content != ''")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, contentPredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = limit

        guard let thoughts = try? context.fetch(request) else { return [] }

        return thoughts.compactMap { thought in
            if thought.content.isEmpty { return nil }
            return String(thought.content.prefix(200))
        }
    }

    /// 获取最近的标签样例（用于 AI prompt 的 existingTagExamples 变量）
    /// - Parameter limit: 数量限制
    /// - Returns: 标签名称数组（按 usageCount 降序）
    func getRecentTagNames(limit: Int = 20) -> [String] {
        let request = ThoughtTag.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "usageCount", ascending: false)]
        request.fetchLimit = limit

        return (try? context.fetch(request).map { $0.name }) ?? []
    }

    // MARK: - Settings Keys

    /// 自动整理开关的 UserDefaults key
    static let autoOrganizationEnabledKey = "isThoughtAutoOrganizationEnabled"

    // MARK: - Private Helpers

    /// 构建 base predicate（排除已删除/归档，可选日期范围）
    private func basePredicate(from startDate: Date?, to endDate: Date?) -> NSPredicate {
        var predicates: [NSPredicate] = [
            NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        ]
        if let start = startDate {
            predicates.append(NSPredicate(format: "createdAt >= %@", start as CVarArg))
        }
        if let end = endDate {
            predicates.append(NSPredicate(format: "createdAt <= %@", end as CVarArg))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// 内部创建 ThoughtTagAssignment（不调用 context.save，由调用方统一 save）
    private func createAssignmentInternal(
        thought: Thought,
        tag: ThoughtTag,
        source: ThoughtTagAssignment.Source,
        confidence: Double
    ) {
        // 去重：同一条想法同一标签同一来源组不重复创建
        let sourceGroup: String
        switch source {
        case .manual, .inline:
            sourceGroup = "high_priority"
        case .confirmedAI, .ai:
            sourceGroup = "ai"
        case .rejectedAI:
            sourceGroup = "rejected"
        }

        if let existing = thought.tagAssignments as? Set<ThoughtTagAssignment> {
            let duplicateExists = existing.contains { assignment in
                assignment.tag == tag && resolveSourceGroup(assignment.source) == sourceGroup
            }
            if duplicateExists { return }
        }

        let assignment = ThoughtTagAssignment(context: context)
        assignment.id = UUID()
        assignment.source = source.rawValue
        assignment.confidence = confidence
        assignment.assignedAt = Date()
        assignment.thought = thought
        assignment.tag = tag
    }

    /// 将 source 归类为来源组（用于去重判断）
    private func resolveSourceGroup(_ source: String) -> String {
        switch ThoughtTagAssignment.Source(rawValue: source) {
        case .manual, .inline: return "high_priority"
        case .confirmedAI, .ai: return "ai"
        case .rejectedAI: return "rejected"
        case .none: return "unknown"
        }
    }
}

// MARK: - Error Types

/// 观点模块错误类型
enum ThoughtError: LocalizedError {
    case notFound
    case tagInUse
    case saveFailed
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "想法不存在"
        case .tagInUse:
            return "标签正在使用中，无法删除"
        case .saveFailed:
            return "保存失败"
        case .unknown(let error):
            return "未知错误：\(error.localizedDescription)"
        }
    }
}

// MARK: - Sort Options

/// 排序选项
enum ThoughtSortOption {
    case createdAtDescending      // 创建时间倒序
    case createdAtAscending       // 创建时间正序
    case updatedAtDescending      // 更新时间倒序
    case mood                     // 按心情排序
}

// MARK: - Filters

/// 筛选条件
struct ThoughtFilters {
    var mood: String?
    var startDate: Date?
    var endDate: Date?
    var tags: [String]?
}
