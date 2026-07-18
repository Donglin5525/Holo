//
//  ThoughtRepository+TagManagement.swift
//  Holo
//
//  观点标签全局管理：删除 / 重命名 / 合并
//  方案：docs/thoughts/plans/2026-07-17-Holo观点标签管理方案.md
//

import Foundation
import CoreData

// MARK: - Tag Deletion Result

/// 全局删除标签的结果
struct TagDeletionResult {
    /// 摘掉的 assignment 数（供 toast 反馈）
    let removedAssignmentCount: Int
    /// 缓存已重算的 Topic ID（测试断言用）
    let affectedTopicIds: [UUID]
}

// MARK: - Tag Rename Outcome

/// 重命名结果（供 UI 反馈文案区分）
enum TagRenameOutcome {
    /// 纯改名（含仅显示差异）
    case renamed
    /// 目标名已存在，已合并
    case merged
}

extension ThoughtRepository {

    // MARK: - 全局删除

    /// 全局删除标签：删除所有 assignments + 删除 tag 实体 + 重算受影响 Topic 缓存
    /// - Parameter name: 标签名（归一化匹配）
    /// - Returns: 删除结果
    /// - Throws: `ThoughtError.tagNameEmpty`（空白名）/ `.notFound`（标签不存在）
    @discardableResult
    func deleteTagGlobally(name: String) throws -> TagDeletionResult {
        let key = ThoughtTagNormalizer.key(name)
        guard !key.isEmpty else { throw ThoughtError.tagNameEmpty }
        guard let tag = try fetchTagByKey(key) else { throw ThoughtError.notFound }

        // 删除前先取受影响 Topic（删除后关系 nullify 取不到）
        let affectedTopics = (tag.associatedTopics as? Set<Topic>) ?? []
        let affectedTopicIds = affectedTopics.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let assignmentCount = (tag.assignments as? Set<ThoughtTagAssignment>)?.count ?? 0

        // 显式断开 Topic 关联（比依赖 delete rule 的生效时机更稳）
        for topic in affectedTopics {
            topic.removeAssociatedTags(tag)
        }

        // 删除实体：thoughts 关系 nullify 自动断开，assignments cascade 自动删除
        context.delete(tag)

        // 重算受影响 Topic 的展示缓存
        for topic in affectedTopics {
            topic.refreshAssociatedTagNamesCache()
            topic.updatedAt = Date()
        }

        try context.save()
        return TagDeletionResult(removedAssignmentCount: assignmentCount, affectedTopicIds: affectedTopicIds)
    }

    // MARK: - 全局重命名

    /// 全局重命名标签
    /// - 目标名（归一化后）不存在 → 直接改名
    /// - 目标名已存在 → 合并：assignments/thoughts/Topic 关联迁移到目标 tag，删除源 tag
    /// - 归一化同 key 仅显示差异（大小写/全半角）→ 只更新 displayName
    /// - Parameters:
    ///   - oldName: 原标签名
    ///   - newName: 新标签名
    /// - Returns: 重命名结果（renamed / merged）
    /// - Throws: `ThoughtError.tagNameEmpty`（空白名）/ `.notFound`（源标签不存在）
    @discardableResult
    func renameTag(from oldName: String, to newName: String) throws -> TagRenameOutcome {
        let oldKey = ThoughtTagNormalizer.key(oldName)
        let newDisplayName = ThoughtTagNormalizer.displayName(newName)
        let newKey = ThoughtTagNormalizer.key(newDisplayName)
        guard !oldKey.isEmpty, !newKey.isEmpty else { throw ThoughtError.tagNameEmpty }
        guard let sourceTag = try fetchTagByKey(oldKey) else { throw ThoughtError.notFound }

        if oldKey == newKey {
            // 仅显示名差异：更新 displayName + 刷新 Topic 缓存
            sourceTag.name = newDisplayName
            refreshTopicCaches(for: sourceTag)
            try context.save()
            return .renamed
        }

        if let targetTag = try fetchTagByKey(newKey) {
            mergeTag(source: sourceTag, into: targetTag)
            try context.save()
            return .merged
        } else {
            sourceTag.name = newDisplayName
            refreshTopicCaches(for: sourceTag)
            try context.save()
            return .renamed
        }
    }

    // MARK: - 路径前缀重命名（多级标签子树）

    /// 路径前缀重命名：「工作」→「项目」时，「工作」「工作/Holo」「工作/Holo/编辑器」整棵子树同步改名
    /// 每个子路径独立走 rename 语义（目标已存在则合并），按路径深度升序处理（先父后子）
    /// - Returns: 根路径的重命名结果（renamed / merged，供 UI 反馈文案区分）
    /// - Throws: `ThoughtError.tagNameEmpty`（空白名）/ `.notFound`（源路径不存在）
    @discardableResult
    func renameTagPathPrefix(from oldPath: String, to newPath: String) throws -> TagRenameOutcome {
        let oldKey = ThoughtTagNormalizer.key(oldPath)
        let newDisplayPath = ThoughtTagNormalizer.displayPath(newPath)
        guard !oldKey.isEmpty, !ThoughtTagNormalizer.key(newDisplayPath).isEmpty else {
            throw ThoughtError.tagNameEmpty
        }

        // 收集整棵子树（自身 + 以 oldKey/ 为前缀的路径），按深度升序
        let request = ThoughtTag.fetchRequest()
        let subtree = try context.fetch(request)
            .filter {
                let key = ThoughtTagNormalizer.key($0.name)
                return key == oldKey || key.hasPrefix(oldKey + "/")
            }
            .sorted {
                $0.name.components(separatedBy: "/").count < $1.name.components(separatedBy: "/").count
            }

        guard !subtree.isEmpty else { throw ThoughtError.notFound }

        let oldDepth = oldKey.components(separatedBy: "/").count
        var rootOutcome: TagRenameOutcome = .renamed

        for tag in subtree where !tag.isDeleted {
            // 用原展示路径的尾段保留大小写：新路径 = newDisplayPath + 原尾段
            let displaySegments = ThoughtTagNormalizer.displayPath(tag.name).components(separatedBy: "/")
            let suffixSegments = displaySegments.dropFirst(oldDepth)
            let renamedPath = ([newDisplayPath] + suffixSegments).joined(separator: "/")

            let outcome = try renameTag(from: tag.name, to: renamedPath)
            if tag === subtree.first {
                rootOutcome = outcome
            }
        }

        return rootOutcome
    }

    // MARK: - Private Helpers

    /// 按归一化 key 查标签（标签量小，内存匹配即可，与 getOrCreateTag 同模式）
    private func fetchTagByKey(_ key: String) throws -> ThoughtTag? {
        let request = ThoughtTag.fetchRequest()
        return try context.fetch(request).first { ThoughtTagNormalizer.key($0.name) == key }
    }

    /// 合并标签：把 source 的 thoughts/assignments/Topic 关联迁移到 target，删除 source
    /// 同想法去重规则：高优先级来源胜出（manual > inline > confirmedAI > ai > rejectedAI），与 createAssignmentInternal 同源
    private func mergeTag(source: ThoughtTag, into target: ThoughtTag) {
        // 1. 迁移 thoughts 多对多关系
        if let thoughts = source.thoughts as? Set<Thought> {
            for thought in thoughts {
                source.removeThoughts(thought)
                target.addThoughts(thought)
            }
        }

        // 2. 迁移 assignments：按想法去重，高优先级来源胜出
        let targetAssignments = (target.assignments as? Set<ThoughtTagAssignment>) ?? []
        var winnerByThought: [UUID: ThoughtTagAssignment] = [:]
        for assignment in targetAssignments where !assignment.isDeleted {
            guard let thoughtId = assignment.thought?.id else { continue }
            if let existing = winnerByThought[thoughtId] {
                if Self.sourcePriority(assignment.source) > Self.sourcePriority(existing.source) {
                    winnerByThought[thoughtId] = assignment
                }
            } else {
                winnerByThought[thoughtId] = assignment
            }
        }

        let sourceAssignments = (source.assignments as? Set<ThoughtTagAssignment>) ?? []
        for assignment in sourceAssignments {
            guard let thoughtId = assignment.thought?.id else {
                context.delete(assignment)  // 孤儿数据直接清
                continue
            }
            if let winner = winnerByThought[thoughtId] {
                if Self.sourcePriority(assignment.source) > Self.sourcePriority(winner.source) {
                    context.delete(winner)
                    assignment.tag = target
                    winnerByThought[thoughtId] = assignment
                } else {
                    context.delete(assignment)
                }
            } else {
                assignment.tag = target
                winnerByThought[thoughtId] = assignment
            }
        }

        // 3. 迁移 Topic 关联
        let affectedTopics = (source.associatedTopics as? Set<Topic>) ?? []
        for topic in affectedTopics {
            source.removeAssociatedTopics(topic)
            target.addAssociatedTopics(topic)
        }

        // 4. 删除源实体
        context.delete(source)

        // 5. 重算目标 usageCount（可见来源 assignments 的去重想法数，与 fetchAITagBuckets 口径一致）
        target.usageCount = Int16(clamping: visibleThoughtCount(for: target))

        // 6. 重算目标关联的全部 Topic 缓存（覆盖迁移过来的 + 原有的）
        refreshTopicCaches(for: target)
    }

    /// 来源优先级（合并去重用）：manual > inline > confirmedAI > ai > rejectedAI
    private static func sourcePriority(_ source: String) -> Int {
        switch ThoughtTagAssignment.Source(rawValue: source) {
        case .manual: return 4
        case .inline: return 3
        case .confirmedAI: return 2
        case .ai: return 1
        case .rejectedAI, .none: return 0
        }
    }

    /// 标签的可见 assignment 去重想法数（usageCount 重算口径）
    private func visibleThoughtCount(for tag: ThoughtTag) -> Int {
        let assignments = (tag.assignments as? Set<ThoughtTagAssignment>) ?? []
        var thoughtIds: Set<UUID> = []
        for assignment in assignments where !assignment.isDeleted {
            guard assignment.rejectedAt == nil,
                  ThoughtRepository.visibleTagSourceValues.contains(assignment.source),
                  let thoughtId = assignment.thought?.id else { continue }
            thoughtIds.insert(thoughtId)
        }
        return thoughtIds.count
    }

    /// 重算标签关联的全部 Topic 展示缓存
    private func refreshTopicCaches(for tag: ThoughtTag) {
        for topic in (tag.associatedTopics as? Set<Topic>) ?? [] {
            topic.refreshAssociatedTagNamesCache()
            topic.updatedAt = Date()
        }
    }
}
