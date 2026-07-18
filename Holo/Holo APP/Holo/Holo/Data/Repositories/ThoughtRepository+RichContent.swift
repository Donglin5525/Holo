//
//  ThoughtRepository+RichContent.swift
//  Holo
//
//  观点模块 - 结构化内容（#/@ Token）的候选查询与引用关系重建
//

import CoreData

extension ThoughtRepository {

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
            let lhsRank = tagMatchRank(tagKey: ThoughtTagNormalizer.key(lhs.name), queryKey: queryKey)
            let rhsRank = tagMatchRank(tagKey: ThoughtTagNormalizer.key(rhs.name), queryKey: queryKey)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsUsed = lhs.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.usageCount > rhs.usageCount
        }

        return Array(ranked.prefix(limit))
    }

    /// 匹配权重：完全匹配 0 > 路径前缀 1 > 段前缀 2 > 包含 3
    private func tagMatchRank(tagKey: String, queryKey: String) -> Int {
        if tagKey == queryKey { return 0 }
        if tagKey.hasPrefix(queryKey) { return 1 }
        if tagKey.components(separatedBy: "/").contains(where: { $0.hasPrefix(queryKey) }) { return 2 }
        return 3
    }

    // MARK: - @ 引用候选

    /// 引用候选查询（排除当前正在编辑的想法，防止自引用）
    /// - 空关键词：最近编辑（updatedAt 降序）
    /// - 有关键词：首行/正文/标签名匹配，按最近编辑排序
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
        request.fetchLimit = limit

        return try context.fetch(request)
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
