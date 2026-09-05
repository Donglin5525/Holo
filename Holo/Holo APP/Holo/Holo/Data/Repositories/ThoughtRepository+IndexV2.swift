//
//  ThoughtRepository+IndexV2.swift
//  Holo
//
//  想法自动整理 V2 数据操作（2026-09-05 方案 §7/§8）
//
//  快照读取、原子落库（版本一致性校验在事务内）、旧数据迁移、
//  自动合集统计与用户纠正（移除/不再使用/隐藏合集）。
//

import Foundation
import CoreData

// MARK: - 落库结果值类型（Service → Repository 的纯数据契约）

/// 一条通过校验的 V2 整理结果（existingRef 或 newConcept 二选一）
struct ThoughtIndexAssignmentOutcome: Equatable {
    enum Concept: Equatable {
        case existing(tagId: UUID)
        case newConcept(name: String, definition: String)
    }
    let concept: Concept
    let evidenceQuote: String
}

/// 一次整理任务的最终结果（0 个 assignment 也是合法完成态）
struct ThoughtIndexTaskOutcome {
    let assignments: [ThoughtIndexAssignmentOutcome]
    /// provisional：仅经名称召回路径产生的新概念（不进全局词典，不生成首页合集）
    let catalogCoverage: String
}

extension ThoughtRepository {

    // MARK: - 快照读取

    /// 全库词条索引快照（投影/目录构造的统一输入）
    func fetchTagIndexSnapshots() throws -> [ThoughtTagIndexSnapshot] {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        return try context.fetch(request).map { tag in
            ThoughtTagIndexSnapshot(
                id: tag.id,
                name: tag.name,
                semanticName: tag.semanticName,
                semanticDefinition: tag.semanticDefinition,
                aliases: Self.decodeAliases(tag.aliasesJSON),
                indexKind: ThoughtTagIndexKind(rawValue: tag.indexKind ?? ""),
                nameLockedByUser: tag.nameLockedByUser,
                mergedIntoTagID: tag.mergedIntoTagID,
                autoSuggestionBlocked: tag.autoSuggestionBlocked,
                autoCollectionHidden: tag.autoCollectionHidden
            )
        }
    }

    /// 单条想法的关系索引快照
    func fetchAssignmentIndexSnapshots(thoughtId: UUID) throws -> [ThoughtAssignmentIndexSnapshot] {
        guard let thought = try fetchByIdInternal(thoughtId) else { return [] }
        let assignments = (thought.tagAssignments as? Set<ThoughtTagAssignment>) ?? []
        return assignments.map { assignment in
            ThoughtAssignmentIndexSnapshot(
                id: assignment.id,
                thoughtId: thoughtId,
                tagId: assignment.tag?.id ?? assignment.id,
                source: assignment.sourceEnum,
                indexVersion: assignment.indexVersion,
                indexState: ThoughtIndexState(rawValue: assignment.indexState ?? ""),
                basisTextHash: assignment.basisTextHash,
                evidenceQuote: assignment.evidenceQuote
            )
        }
    }

    static func decodeAliases(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let aliases = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return aliases.filter { !$0.isEmpty }
    }

    static func encodeAliases(_ aliases: [String]) -> String? {
        let unique = Array(Set(aliases.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(unique) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - V2 整理任务发起标记

    /// 发起整理前写入版本标记与操作 ID（响应到达后据此校验一致性）
    func markIndexRequested(thoughtId: UUID, textHash: String, operationId: UUID) throws {
        guard let thought = try fetchByIdInternal(thoughtId) else {
            throw ThoughtError.notFound
        }
        thought.indexRequestedHash = textHash
        thought.indexOperationID = operationId
        try context.save()
    }

    // MARK: - 终态完成（0 标签也是合法完成态）

    /// deferred 终态（审核拦截/目录超预算）：写完成标记防重跑，保留无标签状态
    func completeIndexWithoutTags(thoughtId: UUID, textHash: String) throws {
        guard let thought = try fetchByIdInternal(thoughtId) else { return }
        thought.indexCompletedHash = textHash
        thought.indexEngineVersion = ThoughtIndexV2Policy.engineVersion
        thought.organizedStatus = "organized"
        thought.organizationStartedAt = nil
        try context.save()
    }

    // MARK: - 原子落库（方案 §7.5）

    /// 应用 V2 整理结果。同一事务内依次校验：想法存在且未软删、正文版本一致、
    /// 授权仍有效；通过后新写本版自动关系、上一版自动关系标 superseded、
    /// 写完成标记。任何校验失败丢弃结果并返回 false（不抛错——迟到结果不是异常）。
    ///
    /// - Parameters:
    ///   - textHash: 发起时的正文 hash（同时是本次结果的 basisTextHash）
    ///   - engineVersion: 产生结果的引擎版本
    @discardableResult
    func applyThoughtIndexV2Result(
        thoughtId: UUID,
        textHash: String,
        outcome: ThoughtIndexTaskOutcome,
        engineVersion: String
    ) throws -> Bool {
        guard let thought = try fetchByIdInternal(thoughtId),
              thought.deletedAt == nil,
              // 正文版本一致：请求发出后正文被编辑 → 旧结果作废
              thought.indexRequestedHash == textHash,
              // 当前正文仍是发起时版本（indexRequestedHash 可能被新任务覆盖，双保险）
              ThoughtTagIndexProjection.textHash(thought.content) == textHash else {
            return false
        }

        let tagSnapshots = try fetchTagIndexSnapshots()
        var tagsById: [UUID: ThoughtTagIndexSnapshot] = [:]
        for snapshot in tagSnapshots {
            tagsById[snapshot.id] = snapshot
        }

        let provisionalNewConcepts = outcome.catalogCoverage == "names_recalled"

        // 1) 上一版自动关系退出有效集（保留行备查，不删除）
        for assignment in (thought.tagAssignments as? Set<ThoughtTagAssignment>) ?? []
        where assignment.sourceEnum == .ai && assignment.indexState != ThoughtIndexState.superseded.rawValue {
            assignment.indexState = ThoughtIndexState.superseded.rawValue
        }

        // 2) 写入本版关系（同 canonical 概念与用户已有标签去重）
        let currentUserTagIds = Set(
            ((thought.tagAssignments as? Set<ThoughtTagAssignment>) ?? [])
                .filter { $0.sourceEnum.isHighPriority || $0.sourceEnum == .confirmedAI }
                .compactMap { $0.tag?.id }
        )
        var handledCanonicals: Set<UUID> = []
        for result in outcome.assignments {
            switch result.concept {
            case .existing(let tagId):
                guard let snapshot = tagsById[tagId], snapshot.mergedIntoTagID == nil else { continue }
                let canonical = ThoughtTagIndexProjection.canonicalTagId(tagId, tags: tagsById)
                guard !handledCanonicals.contains(canonical) else { continue }
                guard !currentUserTagIds.contains(tagId) else { continue }
                guard let tag = try fetchTagById(tagId) else { continue }
                appendV2Assignment(
                    thought: thought, tag: tag,
                    quote: result.evidenceQuote, textHash: textHash
                )
                handledCanonicals.insert(canonical)
            case .newConcept(let name, let definition):
                let tag = try getOrCreateTag(name: name)
                if tag.indexKind == nil {
                    tag.indexKind = (provisionalNewConcepts
                        ? ThoughtTagIndexKind.provisional.rawValue
                        : ThoughtTagIndexKind.auto.rawValue)
                }
                if tag.semanticName == nil { tag.semanticName = ThoughtTagNormalizer.lastSegment(name) }
                if tag.semanticDefinition == nil, !definition.isEmpty {
                    tag.semanticDefinition = String(definition.prefix(80))
                }
                guard !handledCanonicals.contains(tag.id) else { continue }
                appendV2Assignment(
                    thought: thought, tag: tag,
                    quote: result.evidenceQuote, textHash: textHash
                )
                handledCanonicals.insert(tag.id)
            }
        }

        // 3) 完成标记：0 标签同样写 completed，防止每次开 App 重跑
        thought.indexCompletedHash = textHash
        thought.indexEngineVersion = engineVersion
        thought.indexAttemptCount = 0
        thought.indexNextAttemptAt = nil
        thought.organizedStatus = "organized"
        thought.organizationStartedAt = nil
        try context.save()
        return true
    }

    private func appendV2Assignment(
        thought: Thought,
        tag: ThoughtTag,
        quote: String,
        textHash: String
    ) {
        let assignment = ThoughtTagAssignment(context: context)
        assignment.id = UUID()
        assignment.sourceEnum = .ai
        assignment.confidence = 1.0
        assignment.assignedAt = Date()
        assignment.indexVersion = ThoughtTagIndexProjection.currentIndexVersion
        assignment.indexState = ThoughtIndexState.active.rawValue
        assignment.basisTextHash = textHash
        assignment.evidenceQuote = String(quote.prefix(80))
        assignment.thought = thought
        assignment.tag = tag
        tag.usageCount += 1
        tag.lastUsedAt = Date()
    }

    private func fetchTagById(_ id: UUID) throws -> ThoughtTag? {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    // MARK: - 旧数据迁移（方案 §8.2，幂等可重跑）

    private static let indexV2MigrationFlagKey = "hasMigratedThoughtIndexV2"

    /// V1 → V2 一次性迁移：
    /// 1. 旧 source=ai 关系（indexVersion==0）标 legacy（保留原数据，不删不转正）；
    /// 2. 词条 indexKind 回填——有用户认可关系 → user（锁定命名）；纯 AI 词 → legacy；
    /// 3. 有用户认可关系的词条 nameLockedByUser = true。
    func migrateLegacyThoughtIndexIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.indexV2MigrationFlagKey) else { return }
        do {
            try migrateLegacyThoughtIndexOnce()
            defaults.set(true, forKey: Self.indexV2MigrationFlagKey)
        } catch {
            // 下次启动重试（幂等）
        }
    }

    func migrateLegacyThoughtIndexOnce() throws {
        let assignmentRequest = ThoughtTagAssignment.fetchRequest()
        assignmentRequest.predicate = NSPredicate(
            format: "source == %@ AND indexState == nil",
            ThoughtTagAssignment.Source.ai.rawValue
        )
        for assignment in try context.fetch(assignmentRequest) {
            assignment.indexState = ThoughtIndexState.legacy.rawValue
        }

        let recognizedSources = [
            ThoughtTagAssignment.Source.manual.rawValue,
            ThoughtTagAssignment.Source.inline.rawValue,
            ThoughtTagAssignment.Source.confirmedAI.rawValue
        ]
        let tagRequest = ThoughtTag.fetchRequest()
        tagRequest.predicate = NSPredicate(format: "indexKind == nil AND deletedAt == nil")
        for tag in try context.fetch(tagRequest) {
            let hasUserRelation = ((tag.assignments as? Set<ThoughtTagAssignment>) ?? [])
                .contains { recognizedSources.contains($0.source) }
            if hasUserRelation {
                tag.indexKind = ThoughtTagIndexKind.user.rawValue
                tag.nameLockedByUser = true
            } else {
                // 纯 V1 AI 词条：不再进 V2 词典与 # 默认候选；历史读取保留
                tag.indexKind = ThoughtTagIndexKind.legacy.rawValue
            }
        }
        try context.save()
    }

    // MARK: - 自动合集统计（方案 §8.3）

    /// 全库有效自动合集（≥minCount 条不同想法的 canonical 概念入口）
    func fetchAutoCollections(minCount: Int = 3) throws -> [ThoughtTagIndexProjection.AutoCollection] {
        let assignmentRequest = ThoughtTagAssignment.fetchRequest()
        assignmentRequest.predicate = NSPredicate(format: """
            source == %@ AND indexVersion == %d AND indexState == %@ AND rejectedAt == nil
            """,
            ThoughtTagAssignment.Source.ai.rawValue,
            ThoughtTagIndexProjection.currentIndexVersion,
            ThoughtIndexState.active.rawValue
        )
        let relations = try context.fetch(assignmentRequest).map { assignment in
            ThoughtAssignmentIndexSnapshot(
                id: assignment.id,
                thoughtId: assignment.thought?.id ?? assignment.id,
                tagId: assignment.tag?.id ?? assignment.id,
                source: assignment.sourceEnum,
                indexVersion: assignment.indexVersion,
                indexState: ThoughtIndexState(rawValue: assignment.indexState ?? ""),
                basisTextHash: assignment.basisTextHash,
                evidenceQuote: assignment.evidenceQuote
            )
        }
        guard !relations.isEmpty else { return [] }

        // 正文 hash 校验：正文已编辑的关系即时失效（不污染合集直到新结果回来）
        let thoughtIds = Array(Set(relations.map(\.thoughtId)))
        let thoughtRequest = Thought.fetchRequest()
        thoughtRequest.predicate = NSPredicate(
            format: "deletedAt == nil AND isArchived == NO AND id IN %@", thoughtIds
        )
        var contentHashes: [UUID: String] = [:]
        var createdAt: [UUID: Date] = [:]
        for thought in try context.fetch(thoughtRequest) {
            contentHashes[thought.id] = ThoughtTagIndexProjection.cachedTextHash(thought.content)
            createdAt[thought.id] = thought.createdAt
        }

        let tags = try fetchTagIndexSnapshots()
        var tagsById: [UUID: ThoughtTagIndexSnapshot] = [:]
        for snapshot in tags {
            tagsById[snapshot.id] = snapshot
        }
        return ThoughtTagIndexProjection.autoCollections(
            effectiveAutoRelations: relations,
            thoughtContentHashes: contentHashes,
            thoughtCreatedAt: createdAt,
            tags: tagsById,
            minCount: minCount
        )
    }

    // MARK: - 用户纠正（方案 §1.2/§8.3）

    /// 全局拒绝：这个概念不再被自动使用（不自动过期；手动添加不受影响）
    func setAutoSuggestionBlocked(tagId: UUID, blocked: Bool) throws {
        guard let tag = try fetchTagById(tagId) else { return }
        tag.autoSuggestionBlocked = blocked
        if blocked {
            // 现存有效自动关系即时退出有效集（该想法的 AI 标签消失，原文与手动标签不动）
            for assignment in (tag.assignments as? Set<ThoughtTagAssignment>) ?? []
            where assignment.sourceEnum == .ai && assignment.indexState == ThoughtIndexState.active.rawValue {
                assignment.indexState = ThoughtIndexState.superseded.rawValue
            }
        }
        try context.save()
    }

    /// 仅隐藏合集入口（不影响打标与筛选）
    func setAutoCollectionHidden(tagId: UUID, hidden: Bool) throws {
        guard let tag = try fetchTagById(tagId) else { return }
        tag.autoCollectionHidden = hidden
        try context.save()
    }

    /// 按概念名找词条（编辑器「不再自动使用」从名字定位）
    func fetchTagIdByName(_ name: String) -> UUID? {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil AND name == %@", name)
        request.fetchLimit = 1
        return (try? context.fetch(request).first)?.id
    }

    // MARK: - 编辑器 # 候选过滤（方案 §8.3）

    /// # 候选默认复用池：用户标签与 V2 有效概念；legacy 垃圾词与 provisional 不进默认候选
    func fetchCatalogEligibleTagCount() -> Int {
        let snapshots = (try? fetchTagIndexSnapshots()) ?? []
        return snapshots.filter { ThoughtTagIndexProjection.isEligibleForCatalog($0) }.count
    }
}
