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
        // 授权变化（2026-09-24 方案 §3 P0：撤回必须取消在途任务并作废代数）
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConsentChange(_:)),
            name: .holoAIDataProcessingConsentDidChange, object: nil)
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

    /// 授权变化：撤回 → 取消任务+代数+1（迟到结果落库前作废）；
    /// 恢复 → 全量对账重新入队（重建范围与开启索引同口径）。
    @objc private func handleConsentChange(_ note: Notification) {
        let granted = (note.userInfo?["granted"] as? Bool) ?? false
        Task {
            if granted {
                await grantConsent()
            } else {
                await revokeConsent()
            }
        }
    }

    /// 全量核对：无有效向量且未删的想法入队 embed；已有向量的入队 relate
    /// （P0-C 存量补跑：解决「开启 relation 后已有向量的想法永不归类」——
    /// 旧实现 relate 内联在 embed 尾部，已有向量提前 return 直接跳过）。
    /// 分页快照入队（每页 500、创建时间倒序=最近内容优先），10 万级历史不整批进内存。
    func reconcileAllThoughts() async {
        guard let store, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        let context = CoreDataStack.shared.viewContext
        var offset = 0
        var enqueued = 0
        let pageSize = 500
        while true {
            let page: [(id: UUID, hash: String)] = await MainActor.run {
                context.performAndWait {
                    let request = Thought.fetchRequest()
                    request.predicate = NSPredicate(format: "deletedAt == nil")
                    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                    request.fetchLimit = pageSize
                    request.fetchOffset = offset
                    // 块内解出值类型快照：托管对象不能跨线程进 Task（行缓存被合并/清理后
                    // 取值得到 nil，非可选 UUID 强桥接直接崩，2026-09-13 真机 SIGTRAP 实证）
                    let thoughts = (try? context.fetch(request)) ?? []
                    return thoughts.compactMap { thought in
                        guard let id = thought.value(forKey: "id") as? UUID,
                              let content = thought.value(forKey: "content") as? String else { return nil }
                        return (id, ThoughtEmbeddingStore.contentHash(of: content))
                    }
                }
            }
            guard !page.isEmpty else { break }
            for snapshot in page {
                let hasVector: Bool = (try? await store.hasActiveItem(
                    thoughtID: snapshot.id, contentHash: snapshot.hash,
                    modelVersion: ThoughtSemanticStore.defaultModelVersion)) ?? false
                if hasVector {
                    // 已有向量：只补 relate（embed 无需重做）
                    if await enqueueRelateIfNeeded(thoughtID: snapshot.id, contentHash: snapshot.hash) {
                        enqueued += 1
                    }
                } else if await enqueueEmbedIfNeeded(thoughtID: snapshot.id, contentHash: snapshot.hash) {
                    enqueued += 1
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        if enqueued > 0 {
            logger.info("对账入队 \(enqueued) 条（累计扫描 \(offset)）")
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

    /// relate 任务去重入队（P0-C）：同 (thought, hash) 无 pending 任务且从未跑过
    /// （relation_candidate 无记录）才入队。跑过的重评（主题目录变更/校准升级）
    /// 属 P2 受控重评，P0 不自动触发——避免 AI 写 link 与重评互相点火成环。
    func enqueueRelateIfNeeded(thoughtID: UUID, contentHash: String) async -> Bool {
        guard let store else { return false }
        do {
            if try await store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "relate") {
                return false
            }
            if try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: contentHash) {
                return false
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "relate",
                priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, lastErrorCode: nil)
            try await store.enqueueJob(job)
            return true
        } catch {
            logger.error("relate 入队失败 thought=\(thoughtID)：\(error.localizedDescription)")
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

    /// 「删除设备智能索引」（设置页）：先停管线节拍并释放内存索引
    /// （否则 30s 心跳继续用旧引用写入、checkpoint 可能把旧向量写回磁盘），
    /// 再销毁语义库与索引缓存。销毁后可重新 bootstrap 重建。
    func destroyIndex() async throws {
        await ThoughtSemanticPipeline.shared.shutdown()
        guard let store else { return }
        try await store.destroyAllData()
        logger.notice("设备智能索引已销毁")
    }
}
