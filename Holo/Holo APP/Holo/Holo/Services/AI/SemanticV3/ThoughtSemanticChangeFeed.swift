//
//  ThoughtSemanticChangeFeed.swift
//  Holo
//
//  统一变更事件源（语义图谱 V3 Phase 2，方案 §9.1）
//
//  创建、正文实质编辑、软删、恢复、永久删除、CloudKit 远端合并——全部经
//  Core Data 保存通知进入同一个 feed；事件以 (thoughtId + contentHash + kind)
//  去重后写入 semantic_job 队列。授权撤回 bump consentGeneration 并取消全部任务。
//
//  设计取舍：观察者模式而非逐点挂钩——散布在 Repository 的钩子会漏远端同步
//  与修复器写入；监听保存通知是「同一事件源」的根治实现（方案 §9.1 明确
//  不能依赖单一游标遍历）。
//

import CoreData
import Foundation
import OSLog

@MainActor
final class ThoughtSemanticChangeFeed {

    static let shared = ThoughtSemanticChangeFeed()

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtSemanticFeed")
    private var store: ThoughtSemanticStore?
    private var started = false
    /// 对账防重入：CloudKit 启动会连发多个 remoteChange，并发 reconcile 会竞态重复入队
    private var isReconciling = false

    /// 注入语义库（App 启动后异步装配；测试注入独立实例）。
    func attach(store: ThoughtSemanticStore) {
        self.store = store
    }

    /// 挂监听（幂等）。App 启动后调用一次。
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSave(_:)),
            name: .NSManagedObjectContextDidSave, object: nil)
        // CloudKit 远端合并（NSPersistentCloudKitContainer 强制开 history tracking）
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRemoteChange(_:)),
            name: .NSPersistentStoreRemoteChange, object: nil)
    }

    // MARK: - 事件处理

    @objc private func handleSave(_ note: Notification) {
        // 只关心主栈 viewContext / background context 的保存（过滤测试与独立栈）
        guard let context = note.object as? NSManagedObjectContext,
              context.persistentStoreCoordinator === CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        else { return }
        let inserted = (note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
        let updated = (note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
        let deleted = (note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []
        handleChanges(inserted: inserted, updated: updated, deleted: deleted)
    }

    @objc private func handleRemoteChange(_ note: Notification) {
        // 远端批量导入：粗粒度全量核对（数量小可接受；量大时 Phase 3 换 history 事务级解析）
        guard let store else { return }
        Task {
            let pending = (try? await store.pendingJobCount()) ?? 0
            logger.debug("远端变更通知：当前待处理 \(pending)")
            await reconcileAllThoughts()
        }
    }

    /// 全量核对：无有效向量且未删的想法入队（启动/远端变更后的兜底对账）。
    func reconcileAllThoughts() async {
        guard let store, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        let context = CoreDataStack.shared.viewContext
        context.performAndWait {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil")
            let thoughts = (try? context.fetch(request)) ?? []
            Task { [thoughts] in
                var enqueued = 0
                for thought in thoughts {
                    if await self.enqueueEmbedIfNeeded(thoughtID: thought.id,
                                                        contentHash: ThoughtEmbeddingStore.contentHash(of: thought.content)) {
                        enqueued += 1
                    }
                }
                if enqueued > 0 {
                    self.logger.info("对账入队 \(enqueued) 条")
                }
            }
        }
    }

    // MARK: - 入队（去重）

    private func handleChanges(inserted: Set<NSManagedObject>, updated: Set<NSManagedObject>, deleted: Set<NSManagedObject>) {
        for mo in deleted where mo.entity.name == "Thought" {
            let id = (mo.value(forKey: "id") as? UUID) ?? UUID()
            Task { await self.handleDeletion(thoughtID: id) }
        }
        for mo in inserted.union(updated) where mo.entity.name == "Thought" {
            guard let id = mo.value(forKey: "id") as? UUID,
                  let content = mo.value(forKey: "content") as? String else { continue }
            let deletedAt = mo.value(forKey: "deletedAt") as? Date
            let hash = ThoughtEmbeddingStore.contentHash(of: content)
            if deletedAt != nil {
                Task { await self.handleSoftDelete(thoughtID: id) }
            } else {
                Task { _ = await self.enqueueEmbedIfNeeded(thoughtID: id, contentHash: hash) }
            }
        }
    }

    /// 版本去重入队（§9.1：thoughtId + contentHash + kind）。
    /// flag 为 off 时同样入队——队列只是本机事实，不触发任何网络行为。
    private func enqueueEmbedIfNeeded(thoughtID: UUID, contentHash: String) async -> Bool {
        guard let store else { return false }
        do {
            if try await store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "embed") {
                return false
            }
            if try await store.hasActiveItem(thoughtID: thoughtID, contentHash: contentHash,
                                             modelVersion: ThoughtSemanticStore.defaultModelVersion) {
                return false // 相同 contentHash/modelVersion 已完成（管线第 2 步版本判定）
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "embed",
                priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, lastErrorCode: nil)
            try await store.enqueueJob(job)
            return true
        } catch {
            logger.error("入队失败 thought=\(thoughtID)：\(error.localizedDescription)")
            return false
        }
    }

    /// 软删：tombstone 向量槽位（可恢复路径保留真身，恢复时按 hash 复用，§14）。
    private func handleSoftDelete(thoughtID: UUID) async {
        guard let store else { return }
        try? await store.tombstoneItem(thoughtID: thoughtID)
    }

    /// 永久删除：清向量真身与任务（关系按 Core Data 删除规则处理）。
    private func handleDeletion(thoughtID: UUID) async {
        guard let store else { return }
        try? await store.tombstoneItem(thoughtID: thoughtID)
    }

    // MARK: - 授权（§5.3）

    /// 撤回 AI 数据处理授权：generation +1、取消全部在途任务。
    /// 已存在的用户 Topic/手动关系/用户标签不动（它们在 Core Data，不在本库）。
    func revokeConsent() async {
        guard let store else { return }
        ThoughtSemanticFeatureFlags.consentGeneration += 1
        // pending/running 任务全部终态化（迟到结果由 generation 校验兜底）
        try? await store.cancelAllJobs()
        logger.notice("授权已撤回，generation=\(ThoughtSemanticFeatureFlags.consentGeneration)")
    }

    /// 恢复授权：全量对账重新入队。
    func grantConsent() async {
        await reconcileAllThoughts()
    }

    /// 「删除设备智能索引」（设置页 Phase 4 接 UI）：销毁语义库与索引缓存。
    func destroyIndex() async throws {
        guard let store else { return }
        try await store.destroyAllData()
        logger.notice("设备智能索引已销毁")
    }
}
