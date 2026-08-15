//
//  ThoughtRepository+RichContent.swift
//  Holo
//
//  观点模块 - 结构化内容（#/@ Token）的候选查询与引用关系重建
//

import CoreData

extension ThoughtRepository {

    /// 候选面板使用的标签轻量快照，避免把后台 context 的 NSManagedObject 带回主线程。
    struct TagCandidateSnapshot: Sendable, Equatable {
        let id: UUID
        let name: String
        let usageCount: Int
        let lastUsedAt: Date?
    }

    /// 候选面板使用的想法轻量快照，避免引用候选查询阻塞编辑器输入。
    struct ReferenceCandidateSnapshot: Sendable, Equatable {
        let id: UUID
        let firstLine: String
        let content: String
        let richContentJSON: String?
        let updatedAt: Date
    }

    /// 引用快照：保存时随结构化内容全量重建引用关系
    struct ReferenceSnapshot {
        let targetId: UUID
        let displayText: String
        let snapshot: String
    }

    // MARK: - # 标签候选

    /// 供 # 候选面板「创建标签」使用：按路径获取或创建标签实体（立即持久化）
    @discardableResult
    func getOrCreateTagEntity(path: String) throws -> ThoughtTag {
        let tag = try getOrCreateTag(name: ThoughtTagNormalizer.displayPath(path))
        tag.lastUsedAt = Date()
        try context.save()
        return tag
    }

    /// 标签候选查询
    /// - 空关键词：按最近使用排序（lastUsedAt 降序，nil 沉底，usageCount 兜底）
    /// - 有关键词：路径包含匹配后按「完全匹配 > 路径前缀 > 段前缀 > 包含」内存排序
    func fetchTagCandidates(query: String, limit: Int = 20) throws -> [ThoughtTag] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            let request = ThoughtTag.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastUsedAt", ascending: false),
                NSSortDescriptor(key: "usageCount", ascending: false)
            ]
            request.fetchLimit = limit
            return try context.fetch(request)
        }

        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name CONTAINS[cd] %@", trimmed)
        request.fetchLimit = 50
        let matched = try context.fetch(request)

        let queryKey = ThoughtTagNormalizer.key(trimmed)
        let ranked = matched.sorted { lhs, rhs in
            let lhsRank = Self.tagMatchRank(tagKey: ThoughtTagNormalizer.key(lhs.name), queryKey: queryKey)
            let rhsRank = Self.tagMatchRank(tagKey: ThoughtTagNormalizer.key(rhs.name), queryKey: queryKey)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsUsed = lhs.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.usageCount > rhs.usageCount
        }

        return Array(ranked.prefix(limit))
    }

    /// 后台查询标签候选并返回值类型快照。
    /// 编辑器候选面板是逐字触发的交互路径，不能让 viewContext fetch 占用主线程。
    func fetchTagCandidateSnapshots(query: String, limit: Int = 20) async throws -> [TagCandidateSnapshot] {
        await CoreDataStack.shared.waitUntilReady()
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let request = ThoughtTag.fetchRequest()

            if trimmed.isEmpty {
                request.sortDescriptors = [
                    NSSortDescriptor(key: "lastUsedAt", ascending: false),
                    NSSortDescriptor(key: "usageCount", ascending: false)
                ]
                request.fetchLimit = limit
            } else {
                request.predicate = NSPredicate(format: "name CONTAINS[cd] %@", trimmed)
                request.fetchLimit = 50
            }

            let tags = try context.fetch(request)
            let queryKey = ThoughtTagNormalizer.key(trimmed)
            let ranked = tags.sorted { lhs, rhs in
                if trimmed.isEmpty {
                    let lhsUsed = lhs.lastUsedAt ?? .distantPast
                    let rhsUsed = rhs.lastUsedAt ?? .distantPast
                    if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
                    return lhs.usageCount > rhs.usageCount
                }

                let lhsRank = Self.tagMatchRank(
                    tagKey: ThoughtTagNormalizer.key(lhs.name),
                    queryKey: queryKey
                )
                let rhsRank = Self.tagMatchRank(
                    tagKey: ThoughtTagNormalizer.key(rhs.name),
                    queryKey: queryKey
                )
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsUsed = lhs.lastUsedAt ?? .distantPast
                let rhsUsed = rhs.lastUsedAt ?? .distantPast
                if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
                return lhs.usageCount > rhs.usageCount
            }

            return ranked.prefix(limit).map {
                TagCandidateSnapshot(
                    id: $0.id,
                    name: $0.name,
                    usageCount: Int($0.usageCount),
                    lastUsedAt: $0.lastUsedAt
                )
            }
        }
    }

    /// 匹配权重：完全匹配 0 > 路径前缀 1 > 段前缀 2 > 包含 3
    fileprivate static func tagMatchRank(tagKey: String, queryKey: String) -> Int {
        if tagKey == queryKey { return 0 }
        if tagKey.hasPrefix(queryKey) { return 1 }
        if tagKey.components(separatedBy: "/").contains(where: { $0.hasPrefix(queryKey) }) { return 2 }
        return 3
    }

    // MARK: - @ 引用候选

    /// 引用候选查询（排除当前正在编辑的想法，防止自引用）
    /// - 空关键词：最近编辑（updatedAt 降序）
    /// - 有关键词：首行精确/前缀/包含优先，再看正文包含，最后按最近编辑排序
    func fetchReferenceCandidates(query: String, excludingThoughtId: UUID?, limit: Int = 20) throws -> [Thought] {
        let request = Thought.fetchRequest()
        var predicates: [NSPredicate] = [NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")]

        if let excludingThoughtId {
            predicates.append(NSPredicate(format: "id != %@", excludingThoughtId as CVarArg))
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let firstLinePredicate = NSPredicate(format: "firstLine CONTAINS[cd] %@", trimmed)
            let contentPredicate = NSPredicate(format: "content CONTAINS[cd] %@", trimmed)
            let tagPredicate = NSPredicate(format: "ANY tags.name CONTAINS[cd] %@", trimmed)
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                firstLinePredicate, contentPredicate, tagPredicate
            ]))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        // 先多取一批再在内存按标题相关性排序，避免“最近 20 条”把精确标题挡掉。
        request.fetchLimit = trimmed.isEmpty ? limit : max(limit * 5, 100)

        let candidates = try context.fetch(request)
        guard !trimmed.isEmpty else { return candidates }
        return candidates
            .sorted {
                let lhsRank = Self.referenceMatchRank(firstLine: $0.firstLine ?? "", content: $0.content, query: trimmed)
                let rhsRank = Self.referenceMatchRank(firstLine: $1.firstLine ?? "", content: $1.content, query: trimmed)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 后台查询引用候选并返回值类型快照。
    /// 只把候选面板需要的字段带回主线程，避免跨线程传递 NSManagedObject。
    func fetchReferenceCandidateSnapshots(
        query: String,
        excludingThoughtId: UUID?,
        limit: Int = 20
    ) async throws -> [ReferenceCandidateSnapshot] {
        await CoreDataStack.shared.waitUntilReady()
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let request = Thought.fetchRequest()
            var predicates: [NSPredicate] = [
                NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
            ]

            if let excludingThoughtId {
                predicates.append(NSPredicate(format: "id != %@", excludingThoughtId as CVarArg))
            }

            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "firstLine CONTAINS[cd] %@", trimmed),
                    NSPredicate(format: "content CONTAINS[cd] %@", trimmed),
                    NSPredicate(format: "ANY tags.name CONTAINS[cd] %@", trimmed)
                ]))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            // 先取更大的候选池，再按标题相关性排序，避免精确标题被最近记录挤出面板。
            request.fetchLimit = trimmed.isEmpty ? limit : max(limit * 5, 100)

            let candidates = try context.fetch(request)
            let ranked = trimmed.isEmpty
                ? candidates
                : candidates.sorted {
                    let lhsRank = Self.referenceMatchRank(firstLine: $0.firstLine ?? "", content: $0.content, query: trimmed)
                    let rhsRank = Self.referenceMatchRank(firstLine: $1.firstLine ?? "", content: $1.content, query: trimmed)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    return $0.updatedAt > $1.updatedAt
                }

            return ranked.prefix(limit).map {
                ReferenceCandidateSnapshot(
                    id: $0.id,
                    firstLine: $0.firstLine ?? "",
                    content: $0.content,
                    richContentJSON: $0.richContentJSON,
                    updatedAt: $0.updatedAt
                )
            }
        }
    }

    /// 引用候选的产品排序：标题命中比正文命中更能代表用户要找的目标想法。
    /// 返回值越小优先级越高；空关键词不调用此规则，直接按更新时间展示。
    fileprivate static func referenceMatchRank(firstLine: String, content: String, query: String) -> Int {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0 }

        let title = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.compare(normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return 0
        }
        if title.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound == title.startIndex {
            return 1
        }
        if title.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return 2
        }
        return content.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil ? 3 : 4
    }

    // MARK: - 引用关系全量重建

    /// 以编辑器当前结构化内容为准，全量重建该想法的引用关系（含快照）
    /// 撤销/整段删除/粘贴覆盖后，关系始终与正文 Token 一致
    func replaceReferences(thoughtId: UUID, references: [ReferenceSnapshot]) throws {
        guard let thought = try fetchByIdInternal(thoughtId) else {
            throw ThoughtError.notFound
        }

        if let existing = thought.references as? Set<ThoughtReference> {
            for reference in existing {
                context.delete(reference)
            }
        }

        for item in references {
            guard let target = try fetchById(item.targetId) else { continue }
            let reference = ThoughtReference(context: context)
            reference.id = UUID()
            reference.createdAt = Date()
            reference.sourceThought = thought
            reference.targetThought = target
            reference.displayText = item.displayText
            reference.snapshot = item.snapshot
        }

        try context.save()
    }
}
