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
    private var wakeTask: Task<Void, Never>?
    /// 对账防重入：CloudKit 启动会连发多个 remoteChange，并发 reconcile 会竞态重复入队
    private var isReconciling = false
    // MARK: 脉络派生定向清理状态（W3，§6 C3）
    /// 同源变更防抖：窗口内的编辑/进出主题/排除/归档/删除/远端合并合并成一次定向清理
    private var followupInvalidationTask: Task<Void, Never>?
    private var pendingFollowupThoughtIDs: Set<UUID> = []
    private var pendingFollowupScopeTouched = false

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
        NotificationCenter.default.addObserver(self, selector: #selector(handleSettingsChange(_:)),
            name: ThoughtSemanticFeatureFlags.settingsDidChange, object: nil)
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
        // 通知由保存上下文同步发出，必须在其队列内读成值快照。
        let pilotScope = ThoughtSemanticFeatureFlags.followupPilotScope()
        let harvested: (events: [(id: UUID, hash: String?, deleted: Bool, needsExclusionReconcile: Bool)],
                        followupThoughtIDs: [UUID],
                        followupScopeTouched: Bool) = context.performAndWait {
            let inserted = (note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
            let updated = (note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
            let deleted = (note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []
            let allObjects = inserted.union(updated).union(deleted)
            let events: [(id: UUID, hash: String?, deleted: Bool, needsExclusionReconcile: Bool)] = allObjects.compactMap { object -> (UUID, String?, Bool, Bool)? in
                guard object.entity.name == "Thought", let id = object.value(forKey: "id") as? UUID else { return nil }
                let unavailable = deleted.contains(object) || (object.value(forKey: "deletedAt") as? Date) != nil
                    || (object.value(forKey: "isArchived") as? Bool) == true
                let content = object.value(forKey: "content") as? String ?? ""
                // 标签级 AI 排除（2026-10-21）：命中排除标签、或仍是排除态但标签事实可能已变（去掉
                // 排除标签的恢复路径），都交给 ExclusionService 双向 reconcile；排除想法永不入队
                let excludedHit = !unavailable && (object as? Thought).map(ThoughtAIAudience.isExcluded) == true
                let status = object.value(forKey: "organizedStatus") as? String
                let needsReconcile = excludedHit
                    || (!unavailable && status == ThoughtAIClassificationPolicy.excludedStatus)
                return (id, content.isEmpty ? nil : ThoughtSemanticText.contentHash(content), unavailable, needsReconcile)
            }
            // 脉络派生失效观察（W3，§6 C3）：Thought 的编辑/归档/删除（含远端合并的
            // 保存，同一事件源）+ 试点范围的 ThoughtTopicLink 进出 + Topic 结构变化
            //（改名由清理侧 resolveValid 仍有效自然跳过）。
            var followupThoughtIDs = events.filter { $0.deleted || $0.hash != nil }.map(\.id)
            var followupScopeTouched = false
            if let pilotScope {
                for object in allObjects {
                    switch object.entity.name {
                    case "ThoughtTopicLink":
                        // 删除中的 link 关系可能已不可解析，取不到就交给读侧兜底（读时再验）
                        if let thoughtID = (object.value(forKey: "thought") as? Thought)?.id,
                           let topicID = (object.value(forKey: "topic") as? Topic)?.id,
                           topicID == pilotScope {
                            followupThoughtIDs.append(thoughtID)
                        }
                    case "Topic":
                        if let topicID = object.value(forKey: "id") as? UUID, topicID == pilotScope {
                            followupScopeTouched = true
                        }
                    default: break
                    }
                }
            }
            return (events, followupThoughtIDs, followupScopeTouched)
        }
        Task { @MainActor in
            for event in harvested.events {
                if event.deleted { await handleSoftDelete(thoughtID: event.id) }
                else if event.needsExclusionReconcile {
                    // 双向收敛：新命中→excluded+清痕迹；标签事实已解除→回 pending 重新入队（其 save
                    // 会再次进入 handleSave 走正常 embed 入队，自然收敛不循环）
                    await ThoughtAIExclusionService.shared.reconcile(thoughtIDs: [event.id])
                }
                else if let hash = event.hash { _ = await enqueueEmbedIfNeeded(thoughtID: event.id, contentHash: hash, priority: 100) }
            }
            if !harvested.followupThoughtIDs.isEmpty || harvested.followupScopeTouched {
                invalidateFollowupDerived(thoughtIDs: harvested.followupThoughtIDs,
                                          scopeTouched: harvested.followupScopeTouched)
            }
            scheduleWake()
        }
    }

    @objc private func handleSettingsChange(_ note: Notification) {
        Task {
            try? await store?.cancelAllJobs()
            // 试点范围切换/关闭（setFollowupPilot → settingsDidChange 链路，W3）：
            // 旧 scope 未终态行直接取消终态——不占日额度、不靠领取逐拍以
            // anchor_unavailable 排干；cancelled 行由 upsertFollowupTask 复活，
            // 重新启用后同键可重算
            try? await store?.cancelFollowupTasksOutsideScope(
                keep: ThoughtSemanticFeatureFlags.followupPilotScope())
            await ThoughtAutomaticTopicDiscovery.shared.retryNow()
            await reconcileAllThoughts()
            await ThoughtSemanticPipeline.shared.kickQueue()
            // 开关/试点范围变化：打开中的脉络与相关视图立即撤掉旧证据（§2 A08；
            // kickQueue 内的 followup process 同步对资格链断开的旧范围取消在途）
            postFollowupDerivedDidChange()
        }
    }

    // MARK: - 脉络派生定向清理（W3，2026-11-16 方案 §6 C3「统一收口给 ChangeFeed」）

    /// 变更汇聚入口：handleSave（编辑/归档/删除/进出主题/远端合并）与
    /// ThoughtAIExclusionService（加「不参与 AI」）都汇到这里，同源变更防抖后
    /// 一次定向清理；结束时广播失效事件让打开中的视图立即撤掉旧证据。
    func invalidateFollowupDerived(thoughtIDs: [UUID], scopeTouched: Bool = false) {
        guard !thoughtIDs.isEmpty || scopeTouched else { return }
        pendingFollowupThoughtIDs.formUnion(thoughtIDs)
        pendingFollowupScopeTouched = pendingFollowupScopeTouched || scopeTouched
        followupInvalidationTask?.cancel()
        followupInvalidationTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            followupInvalidationTask = nil
            await runFollowupInvalidation()
        }
    }

    private func runFollowupInvalidation() async {
        guard let store else { return }
        let affected = pendingFollowupThoughtIDs
        pendingFollowupThoughtIDs = []
        let scopeTouched = pendingFollowupScopeTouched
        pendingFollowupScopeTouched = false
        defer { postFollowupDerivedDidChange() }
        // 无试点范围时无 scope 可清（已销毁范围由撤权/索引销毁/范围退出路径处理），
        // 只广播事件让视图按统一资格收敛为空
        guard let scopeID = ThoughtSemanticFeatureFlags.followupPilotScope(),
              scopeTouched || !affected.isEmpty else { return }
        do {
            let cleared = try await ThoughtFollowupInvalidation.run(store: store,
                                                                    scopeID: scopeID,
                                                                    affectedThoughtIDs: affected)
            if cleared > 0 {
                logger.info("脉络派生定向清理：\(cleared) 批次失效")
            }
        } catch {
            // 清理失败不影响主流程，读侧校验兜底（§6 C3「读时再验」）
            logger.error("脉络派生定向清理失败（读侧校验兜底）：\(error.localizedDescription)")
        }
    }

    private func postFollowupDerivedDidChange() {
        NotificationCenter.default.post(name: ThoughtFollowupProjection.followupDerivedDidChange, object: nil)
    }
    /// 输入停止后再处理，保存本身不等待网络。
    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            // 防抖只取消等待阶段；AI 保存关系会再次通知，不能把正在执行的整批整理取消。
            wakeTask = nil
            await reconcileAllThoughts()
            await ThoughtSemanticPipeline.shared.kickQueue()
        }
    }

    @objc private func handleRemoteChange(_ note: Notification) {
        // 远端批量导入：粗粒度全量核对（数量小可接受；量大时 Phase 3 换 history 事务级解析）
        guard let store else { return }
        Task {
            let pending = (try? await store.pendingJobCount()) ?? 0
            logger.debug("远端变更通知：当前待处理 \(pending)")
            // 多设备：另一台设备的排除开关/清理墓碑经 CloudKit 同步过来，本机向量库与
            // 排除状态需要按标签事实重判（ExclusionService 每次回读事实源，幂等）
            await ThoughtAIExclusionService.shared.reconcileAll()
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
        guard ThoughtSemanticFeatureFlags.index != .off, let store, !isReconciling else { return }
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
                    // 「不参与 AI」标签的想法不入队（embed/relate 都不碰）
                    request.predicate = ThoughtAIAudience.aiVisible(
                        NSPredicate(format: "deletedAt == nil AND isArchived == NO"))
                    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                    request.fetchLimit = pageSize
                    request.fetchOffset = offset
                    // 块内解出值类型快照：托管对象不能跨线程进 Task（行缓存被合并/清理后
                    // 取值得到 nil，非可选 UUID 强桥接直接崩，2026-09-13 真机 SIGTRAP 实证）
                    let thoughts = (try? context.fetch(request)) ?? []
                    return thoughts.compactMap { thought in
                        guard let id = thought.value(forKey: "id") as? UUID,
                              let content = thought.value(forKey: "content") as? String else { return nil }
                        return (id, ThoughtSemanticText.contentHash( content))
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

    /// 版本去重入队（§9.1：thoughtId + contentHash + kind）。
    /// flag 为 off 时同样入队——队列只是本机事实，不触发任何网络行为。
    private func enqueueEmbedIfNeeded(thoughtID: UUID, contentHash: String, priority: Int = 0) async -> Bool {
        guard ThoughtSemanticFeatureFlags.index != .off, let store else { return false }
        // 编辑中的中间版本不入队（2026-11-16 时机根治）：正文未定稿就分类，
        // 既拿半截内容猜主题、又打断写作。编辑结束由 handleEditingEnded 定稿入队。
        guard !ThoughtEditingSessionRegistry.shared.isEditing(thoughtID) else { return false }
        do {
            if try await store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "embed") {
                return false
            }
            if try await store.hasActiveItem(thoughtID: thoughtID, contentHash: contentHash,
                                             modelVersion: ThoughtSemanticStore.defaultModelVersion) {
                return await enqueueRelateIfNeeded(thoughtID: thoughtID, contentHash: contentHash, priority: priority)
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "embed",
                priority: priority, state: "pending", attemptCount: 0, nextAttemptAt: Date().addingTimeInterval(priority > 0 ? 5 : 0),
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
    func enqueueRelateIfNeeded(thoughtID: UUID, contentHash: String, priority: Int = 0) async -> Bool {
        guard ThoughtSemanticFeatureFlags.relation != .off, let store else { return false }
        // 编辑中的中间版本不入队（口径同 embed，见 enqueueEmbedIfNeeded）
        guard !ThoughtEditingSessionRegistry.shared.isEditing(thoughtID) else { return false }
        do {
            if try await store.hasPendingJob(thoughtID: thoughtID, contentHash: contentHash, kind: "relate") {
                return false
            }
            let evaluationVersion = await ThoughtTopicVerifier.evaluationVersion(context: CoreDataStack.shared.viewContext)
            if try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: contentHash, evaluationVersion: evaluationVersion) {
                return false
            }
            let job = ThoughtSemanticStore.SemanticJob(
                id: UUID(), thoughtID: thoughtID, contentHash: contentHash, kind: "relate",
                priority: priority, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration, lastErrorCode: nil)
            try await store.enqueueJob(job)
            return true
        } catch {
            logger.error("relate 入队失败 thought=\(thoughtID)：\(error.localizedDescription)")
            return false
        }
    }

    /// 编辑会话结束（编辑器 onDisappear 兜底落库后调用）：用定稿正文按去重规则入队，
    /// 补上编辑期间被「编辑中不入队」闸住的版本。删除/归档/排除想法查询自然落空，跳过。
    /// 编辑中途被杀（没有走到这里）由启动对账 reconcileAllThoughts 兜底。
    func handleEditingEnded(thoughtID: UUID) async {
        guard ThoughtSemanticFeatureFlags.index != .off, let store else { return }
        let context = CoreDataStack.shared.viewContext
        var finalHash: String?
        context.performAndWait {
            let request = Thought.fetchRequest()
            request.predicate = ThoughtAIAudience.processablePredicate(thoughtID: thoughtID)
            guard let thought = (try? context.fetch(request))?.first,
                  let content = thought.value(forKey: "content") as? String, !content.isEmpty
            else { return }
            finalHash = ThoughtSemanticText.contentHash(content)
        }
        guard let finalHash else { return }
        _ = await enqueueEmbedIfNeeded(thoughtID: thoughtID, contentHash: finalHash, priority: 100)
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
        // 脉络核对撤权收口（W3，§6 C3「撤授权时取消在途并清除新增派生 JSON」）：
        // 取消在途核对、清能力缓存、当前试点范围整体退出清理（含 quotes 的判定
        // JSON 不留设备；隐藏回执仅含稳定 ID，按规格保留——「清除设备索引」才清）
        await ThoughtFollowupCoordinator.shared.cancelActiveRun()
        await ThoughtFollowupCapabilityCache.shared.invalidate()
        if let scopeID = ThoughtSemanticFeatureFlags.followupPilotScope() {
            try? await store.destroyFollowupData(scopeID: scopeID)
        }
        postFollowupDerivedDidChange()
        logger.notice("授权已撤回，generation=\(ThoughtSemanticFeatureFlags.consentGeneration)")
    }

    /// 恢复授权：全量对账重新入队。
    func grantConsent() async {
        await reconcileAllThoughts()
    }

    /// 「删除设备智能索引」（设置页）：先停管线节拍并释放内存索引
    /// （否则 30s 心跳继续用旧引用写入、checkpoint 可能把旧向量写回磁盘），
    /// 再销毁语义库与索引缓存。销毁后可重新 bootstrap 重建。
    /// followup 三表（结果/来源/隐藏回执）随 semantic.sqlite 一并销毁
    ///（§6 C3「清除设备索引按现有入口清掉本机反馈」）；shutdown 内已取消在途核对。
    func destroyIndex() async throws {
        await ThoughtSemanticPipeline.shared.shutdown()
        guard let store else { return }
        try await store.destroyAllData()
        postFollowupDerivedDidChange()
        logger.notice("设备智能索引已销毁")
    }
}
