//
//  ThoughtAIExclusionService.swift
//  Holo
//
//  标签级 AI 排除执行服务（2026-10-21 方案）：标签开关、双向 reconcile、存量清理、派生记忆级联
//

import Foundation
import CoreData
import OSLog

/// 排除的落地执行者。actor 串行 + 每次 reconcile 回读 CoreData 事实源按当前值收敛：
/// 快速开-关-开时「最后状态胜出」而非「最后写胜出」，无需代数号。
///
/// 双向幂等：命中排除 → organizedStatus=excluded + 撤 AI 痕迹；不再命中但仍是 excluded → 回 pending
/// 重新入队。触发方：标签开关（UI）、编辑保存（EditorCommit）、标签合并/删除（TagManagement）、
/// ChangeFeed / reconcileAllThoughts（多设备与启动兜底）。
actor ThoughtAIExclusionService {

    static let shared = ThoughtAIExclusionService()

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtAIExclusion")

    private init() {}

    // MARK: - 入口

    /// 标签排除开关（「AI 分析范围」子页 / 标签管理页盾牌）。
    /// 返回本次实际改变状态的想法条数（供 UI 摘要与确认弹窗提示）。
    @discardableResult
    func setTagExcluded(tagID: UUID, _ excluded: Bool) async -> Int {
        let candidates = (try? await CoreDataStack.shared.performBackgroundTask { context -> [UUID] in
            let request = ThoughtTag.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", tagID as CVarArg)
            request.fetchLimit = 1
            guard let tag = try context.fetch(request).first else { return [] }
            tag.excludeFromAI = excluded
            try context.save()
            return try Self.candidateThoughtIDs(for: tag, includeCurrentlyExcluded: !excluded, in: context)
        }) ?? []
        return await reconcile(thoughtIDs: candidates)
    }

    /// 双向 reconcile：一批想法的排除标记与标签事实对齐。
    @discardableResult
    func reconcile(thoughtIDs: [UUID]) async -> Int {
        guard !thoughtIDs.isEmpty else { return 0 }
        let outcome = (try? await CoreDataStack.shared.performBackgroundTask { context in
            Self.performReconcile(thoughtIDs: thoughtIDs, in: context)
        }) ?? (excluded: [], restored: 0)
        if !outcome.excluded.isEmpty {
            await purgeSemanticArtifacts(for: outcome.excluded)
        }
        if outcome.excluded.count + outcome.restored > 0 {
            logger.info("AI 排除 reconcile：退出 \(outcome.excluded.count) 条，恢复 \(outcome.restored) 条")
        }
        return outcome.excluded.count + outcome.restored
    }

    /// reconcile 的 CoreData 部分（internal 供单测直调；向量/记忆清理由 actor 侧接着做）。
    static func performReconcile(
        thoughtIDs: [UUID], in context: NSManagedObjectContext
    ) -> (excluded: [UUID], restored: Int) {
        var excluded: [UUID] = []
        var restored = 0
        var touchedTopics = Set<NSManagedObjectID>()
        for id in Set(thoughtIDs) {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
            request.fetchLimit = 1
            guard let thought = try? context.fetch(request).first else { continue }
            let hit = ThoughtAIAudience.isExcluded(thought)
            let marked = thought.organizedStatus == ThoughtAIClassificationPolicy.excludedStatus
            if hit {
                // 命中即收集：未标记的落地状态；已标记的（多设备同步先到）也要幂等清一次
                // CoreData 外痕迹（本机向量库不同步，可能残留）
                if !marked {
                    touchedTopics.formUnion(applyExclusion(to: thought))
                }
                excluded.append(id)
            } else if marked {
                // 恢复：save 事件触发 ChangeFeed 重新入队（向量已 tombstone，hasActiveItem 为假必重嵌）
                thought.organizedStatus = "pending"
                restored += 1
            }
        }
        hideEmptiedClassificationTopics(touchedTopics, in: context)
        if context.hasChanges { try? context.save() }
        return (excluded, restored)
    }

    /// 全量兜底（启动 / 远端同步后由 ChangeFeed 调用）：只重判两类——命中未标记、已标记未命中。
    func reconcileAll() async {
        let ids = (try? await CoreDataStack.shared.performBackgroundTask { context -> [UUID] in
            let hitButUnmarked = Thought.fetchRequest()
            hitButUnmarked.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "deletedAt == nil AND organizedStatus != %@", ThoughtAIClassificationPolicy.excludedStatus),
                NSCompoundPredicate(notPredicateWithSubpredicate: ThoughtAIAudience.aiVisiblePredicate()),
            ])
            let markedButClear = Thought.fetchRequest()
            markedButClear.predicate = ThoughtAIAudience.aiVisible(
                NSPredicate(format: "deletedAt == nil AND organizedStatus == %@", ThoughtAIClassificationPolicy.excludedStatus))
            return try (context.fetch(hitButUnmarked) + context.fetch(markedButClear)).map(\.id)
        }) ?? []
        await reconcile(thoughtIDs: ids)
    }

    // MARK: - 私有：候选与落地

    /// 开关的受影响候选：该标签任何关联（assignment/tags 镜像）的想法；
    /// 关闭时还要含全部已标记 excluded 的想法——它们可能由此标签排除，需重判是否仍命中其他排除标签。
    private static func candidateThoughtIDs(
        for tag: ThoughtTag,
        includeCurrentlyExcluded: Bool,
        in context: NSManagedObjectContext
    ) throws -> [UUID] {
        var ids = Set<UUID>()
        if let assignments = tag.assignments as? Set<ThoughtTagAssignment> {
            for assignment in assignments { if let id = assignment.thought?.id { ids.insert(id) } }
        }
        if let thoughts = tag.thoughts as? Set<Thought> { ids.formUnion(thoughts.map(\.id)) }
        if includeCurrentlyExcluded {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(
                format: "organizedStatus == %@ AND deletedAt == nil",
                ThoughtAIClassificationPolicy.excludedStatus)
            ids.formUnion(try context.fetch(request).map(\.id))
        }
        return Array(ids)
    }

    /// 单条想法退出 AI（CoreData 部分，internal 供单测直调）。返回被撤关联的主题，供空主题收口。
    static func applyExclusion(to thought: Thought) -> Set<NSManagedObjectID> {
        thought.organizedStatus = ThoughtAIClassificationPolicy.excludedStatus
        // AI 自动打的标签退出有效集（用户 manual/inline/confirmedAI 关联不动）
        if let assignments = thought.tagAssignments as? Set<ThoughtTagAssignment> {
            for assignment in assignments
            where assignment.source == ThoughtTagAssignment.Source.ai.rawValue && assignment.rejectedAt == nil {
                assignment.indexState = ThoughtIndexState.superseded.rawValue
            }
        }
        // 主题归属走 superseded 而非 rejected：rejected 会被类别理解当「移出反证」捞正文上传（自我泄漏），
        // 且永久阻止 AI 重建该 pair；superseded 不被捞、不算有效成员、关闭排除后可重新归类。
        // recordSuperseded 自带守卫跳过用户决定的关系（用户手动归类保留展示，AI 读取处统一过滤兜底）。
        var topics = Set<NSManagedObjectID>()
        if let links = thought.topicLinks as? Set<ThoughtTopicLink> {
            for link in links where link.stateEnum == .active {
                guard let topic = link.topic else { continue }
                ThoughtTopicLinkProjection.recordSuperseded(thought: thought, topic: topic)
                topics.insert(topic.objectID)
            }
        }
        return topics
    }

    /// 撤关联后成员归零的分类主题收口为 hidden（项目无自动退场规则，此处补上）；
    /// 用户手动激活/确认过的主题由 recordSuperseded 守卫保留关系，不会归零误伤。
    private static func hideEmptiedClassificationTopics(
        _ topicIDs: Set<NSManagedObjectID>, in context: NSManagedObjectContext
    ) {
        for objectID in topicIDs {
            guard let topic = try? context.existingObject(with: objectID) as? Topic,
                  topic.isClassificationTopic,
                  ThoughtTopicLinkProjection.effectiveActiveThoughtCount(of: topic) == 0
            else { continue }
            topic.status = Topic.TopicStatus.hidden.rawValue
            topic.updatedAt = Date()
        }
    }

    /// CoreData 之外的痕迹：向量库墓碑 + 内存索引剔除（tombstone 不自动剔索引）+ 派生记忆级联删除。
    private func purgeSemanticArtifacts(for thoughtIDs: [UUID]) async {
        let store = await ThoughtSemanticPipeline.shared.store
        let index = await ThoughtSemanticPipeline.shared.index
        for id in thoughtIDs {
            try? await store?.tombstoneItem(thoughtID: id)
            try? await index?.remove(id: id)
        }
        // 记忆证据按「含排除想法即删」清理——宁可 AI 少记一条，不可漏一条（口径一：连痕迹一起清）
        let keys = Set(thoughtIDs.map { $0.uuidString.lowercased() })
        let removedLongTerm = await MainActor.run {
            HoloLongTermMemoryStore.deleteMemories(referencingThoughtIDs: keys)
        }
        var removedRecords = 0
        if let repository = try? await HoloMemoryRuntime.shared.repository() {
            removedRecords = (try? await repository.deleteRecordsDerived(fromThoughtIDs: keys)) ?? 0
        }
        if removedLongTerm + removedRecords > 0 {
            logger.info("AI 排除清理派生记忆：长期记忆 \(removedLongTerm) 条，结构化记录 \(removedRecords) 条")
        }
    }
}
