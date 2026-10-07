//
//  ThoughtRepository+EditorCommit.swift
//  Holo
//
//  想法编辑器专用单笔事务提交（2026-10-04 体检 G1「保存可信」）：
//  正文 / 富文本 / 行内标签 / 引用关系在同一笔 context.save() 内原子落库，
//  无变化时跳过写入（不动 updatedAt、不重建标签与引用），
//  行内标签差异只增删 inline 来源，手动标签永不被正文扫描清除。
//

import CoreData
import os.log

/// 编辑器保存回执：committed == false 表示「无变化跳过」，不是失败。
struct ThoughtEditorCommitReceipt: Equatable {
    let thoughtId: UUID
    let committed: Bool
    let savedAt: Date
}

extension ThoughtRepository {

    /// 编辑器会话的单笔想法提交。
    ///
    /// - Parameters:
    ///   - thoughtId: 会话稳定 ID。新建会话首次保存传入预分配的草稿 ID，重复提交按同一 ID
    ///     fetch 后复用，不会产生重复记录。
    ///   - content: 正文（Markdown 形式的绑定文本）。
    ///   - inlineTags: 正文行内 #标签 提取结果。只与现有 inline/manual 来源做差异，
    ///     manual 来源保留；ai/confirmedAI/rejectedAI 不参与本次提交。
    ///   - richContentJSON: 双层可选。外层 nil = 不改动；外层非 nil 写入（内层 nil = 清除）。
    ///   - references: 引用关系目标列表。nil = 不改动；非 nil 全量对齐（含清空）。
    ///   - createIfMissing: 实体不存在时创建（新建会话首次落库 / 草稿续写）。
    ///     编辑已有想法时传 false，避免已删除想法被静默复活。
    @discardableResult
    func commitEditorContent(
        thoughtId: UUID,
        content: String,
        inlineTags: [String] = [],
        richContentJSON: String?? = nil,
        references: [ReferenceSnapshot]? = nil,
        createIfMissing: Bool
    ) throws -> ThoughtEditorCommitReceipt {
        let thought: Thought
        if let existing = try fetchById(thoughtId) {
            thought = existing
        } else if createIfMissing {
            thought = makeEditorThought(id: thoughtId, content: content, richContentJSON: richContentJSON)
        } else {
            throw ThoughtError.notFound
        }

        let contentChanged = thought.content != content
        var richChanged = false
        if let richContentJSON, thought.richContentJSON != richContentJSON {
            thought.richContentJSON = richContentJSON
            richChanged = true
        }

        let tagsChanged = try syncInlineTagsDiff(thought: thought, inlineTags: inlineTags)
        let referencesChanged: Bool
        if let references {
            referencesChanged = try syncReferencesDiff(thought: thought, references: references)
        } else {
            referencesChanged = false
        }

        if !contentChanged && !richChanged && !tagsChanged && !referencesChanged,
           thought.managedObjectContext != nil, !thought.hasChanges {
            // 无任何变化：不写 updatedAt、不 save。打开即退出不产生任何写入痕迹。
            return ThoughtEditorCommitReceipt(thoughtId: thoughtId, committed: false, savedAt: Date())
        }

        if contentChanged {
            thought.content = content
            thought.firstLine = RichContentSerializer.firstLine(fromPlainText: content)
            // V2 §5.5：正文实变且与已整理版本不同 → 回 pending 等待重排（与 update() 同口径）。
            let newHash = ThoughtTagIndexProjection.textHash(content)
            let reorganizableStatuses: Set<String> = ["unprocessed", "organized", "failed", "skipped"]
            if newHash != thought.indexCompletedHash,
               reorganizableStatuses.contains(thought.organizedStatus) {
                thought.organizedStatus = "pending"
                thought.indexRequestedHash = nil
            }
        }

        // 走到这里必然有变化（或新建），才允许刷新 updatedAt。
        thought.updatedAt = Date()

        try context.save()
        return ThoughtEditorCommitReceipt(thoughtId: thoughtId, committed: true, savedAt: Date())
    }

    // MARK: - 新建实体（createIfMissing 路径）

    /// 按会话预分配的稳定 ID 创建想法实体，字段口径与 create() 一致。
    /// 调用方（编辑器）新建会话不传手动标签，行内标签统一走下方差异同步。
    private func makeEditorThought(
        id: UUID,
        content: String,
        richContentJSON: String??
    ) -> Thought {
        let thought = Thought(context: context)
        thought.id = id
        thought.content = content
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.mood = nil
        thought.orderIndex = 0
        thought.imageData = nil
        thought.isSoftDeleted = false
        thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId
        if let richContentJSON {
            thought.richContentJSON = richContentJSON
        }
        thought.firstLine = RichContentSerializer.firstLine(fromPlainText: content)
        thought.organizedStatus = ThoughtAIClassificationPolicy.initialStatus(
            contentLength: content.count,
            isEnabled: ThoughtAIClassificationPolicy.isEnabled()
        )
        return thought
    }

    // MARK: - 行内标签差异同步（手动标签保护）

    /// 把正文 inline 标签与现有 assignment 对齐成一致：
    /// - 只删除 source == inline 且不在新集合中的 assignment；manual 来源永不删除。
    /// - 新集合中缺失的键补建 inline assignment；已被 manual 覆盖的键跳过
    ///   （与 create() 的 manual 优先去重口径一致）。
    /// - ai / confirmedAI / rejectedAI 不参与本次对齐。
    /// - 返回是否有实际变化。
    @discardableResult
    private func syncInlineTagsDiff(thought: Thought, inlineTags: [String]) throws -> Bool {
        // 归一化 + 去重（保持顺序），与 update() 的入参整理同口径
        var seen = Set<String>()
        let desiredDisplayNames = inlineTags
            .map { ThoughtTagNormalizer.displayName($0) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(ThoughtTagNormalizer.key($0)).inserted }
        let desiredKeys = Set(desiredDisplayNames.map { ThoughtTagNormalizer.key($0) })

        let assignments = (thought.tagAssignments as? Set<ThoughtTagAssignment>) ?? []
        var existingInlineKeys = Set<String>()
        var existingManualKeys = Set<String>()
        for assignment in assignments {
            guard let tag = assignment.tag else { continue }
            let key = ThoughtTagNormalizer.key(tag.name)
            let source = ThoughtTagAssignment.Source(rawValue: assignment.source)
            switch source {
            case .inline: existingInlineKeys.insert(key)
            case .manual: existingManualKeys.insert(key)
            default: break
            }
        }

        let effectiveExistingKeys = existingInlineKeys.union(existingManualKeys)
        guard effectiveExistingKeys != desiredKeys else { return false }

        // 1. 删除多余 inline assignment（manual 保留）
        for assignment in assignments {
            guard let source = ThoughtTagAssignment.Source(rawValue: assignment.source),
                  source == .inline else { continue }
            guard let tag = assignment.tag else { continue }
            if !desiredKeys.contains(ThoughtTagNormalizer.key(tag.name)) {
                context.delete(assignment)
            }
        }

        // 2. 补缺失的 inline assignment（manual 已覆盖的跳过）
        for displayName in desiredDisplayNames {
            let key = ThoughtTagNormalizer.key(displayName)
            guard !existingManualKeys.contains(key),
                  !existingInlineKeys.contains(key) else { continue }
            let tag = try getOrCreateTag(name: displayName)
            tag.lastUsedAt = Date()
            createAssignmentInternal(thought: thought, tag: tag, source: .inline, confidence: 1.0)
        }

        // 3. 重建 Thought.tags 关系 = 全部非 rejectedAI assignment 的并集（旧 UI 读 tagArray）
        rebuildTagsRelation(from: thought)
        return true
    }

    /// Thought.tags 关系与 assignment 并集对齐（跳过 rejectedAI），与 update() 第 4 步同口径。
    private func rebuildTagsRelation(from thought: Thought) {
        var unionByKey: [String: ThoughtTag] = [:]
        if let assignments = thought.tagAssignments as? Set<ThoughtTagAssignment> {
            for assignment in assignments {
                guard assignment.rejectedAt == nil,
                      let tag = assignment.tag else { continue }
                unionByKey[ThoughtTagNormalizer.key(tag.name)] = tag
            }
        }
        thought.tags?.forEach { tag in
            if let tag = tag as? ThoughtTag {
                thought.removeTags(tag)
            }
        }
        for tag in unionByKey.values {
            thought.addTags(tag)
        }
    }

    // MARK: - 引用关系差异同步

    /// 引用关系与目标列表对齐（含清空）。完全一致时不动（不删除重建）。
    /// 返回是否有实际变化。
    @discardableResult
    private func syncReferencesDiff(
        thought: Thought,
        references: [ReferenceSnapshot]
    ) throws -> Bool {
        let existing = (thought.references as? Set<ThoughtReference>) ?? []
        let existingKeys = existing.map { key in
            ReferenceIdentity(
                targetId: key.targetThought?.id ?? UUID(),
                displayText: key.displayText ?? "",
                snapshot: key.snapshot ?? ""
            )
        }.sorted()
        let desiredKeys = references.map { item in
            ReferenceIdentity(targetId: item.targetId, displayText: item.displayText, snapshot: item.snapshot)
        }.sorted()

        guard existingKeys != desiredKeys else { return false }

        existing.forEach { context.delete($0) }
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
        return true
    }

    /// 引用身份比较键（可排序）
    private struct ReferenceIdentity: Comparable {
        let targetId: UUID
        let displayText: String
        let snapshot: String

        static func < (lhs: ReferenceIdentity, rhs: ReferenceIdentity) -> Bool {
            if lhs.targetId.uuidString != rhs.targetId.uuidString {
                return lhs.targetId.uuidString < rhs.targetId.uuidString
            }
            if lhs.displayText != rhs.displayText {
                return lhs.displayText < rhs.displayText
            }
            return lhs.snapshot < rhs.snapshot
        }
    }
}
