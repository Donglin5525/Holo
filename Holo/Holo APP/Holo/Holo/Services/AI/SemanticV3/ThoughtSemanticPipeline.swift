//
//  ThoughtSemanticPipeline.swift
//  Holo
//
//  语义管线装配与冷启动（语义图谱 V3 Phase 2，方案 §9/§13.4）
//
//  Phase 2 职责：装配 SemanticStore + 索引实现（flag/降级选择）、冷启动
//  load 或 rebuild、旧 JSON 向量一次性迁移（校验后标记，不删原文件）、
//  change feed 挂载。embedding 网络生成与 relate 执行器在 Phase 3 接入。
//

import CoreData
import Foundation
import OSLog

actor ThoughtSemanticPipeline {

    static let shared = ThoughtSemanticPipeline()

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtSemanticPipeline")
    private(set) var store: ThoughtSemanticStore?
    private(set) var index: (any LocalSemanticIndex)?
    private var bootstrapped = false
    private var heartbeatTask: Task<Void, Never>?

    /// 冷启动装配。App 启动后台调用一次（幂等）。
    func bootstrap(root: URL? = nil) async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await CoreDataStack.shared.waitUntilReady()
        guard !Task.isCancelled else { bootstrapped = false; return }

        let semanticStore = await ThoughtSemanticStore(root: root)
        do {
            try await semanticStore.open()
        } catch {
            bootstrapped = false
            logger.error("语义库打开失败：\(error.localizedDescription)")
            return
        }
        store = semanticStore

        // 索引实现选择：USearch（默认）→ 打开失败降级 flat（同过门禁，方案 §8.1）
        let manifest = try? await semanticStore.manifest()
        let dimension = 1024   // 与后端 embeddings 模型一致（config.js dimensions 默认）
        let indexDir = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let usearch = USearchSemanticIndex(dimension: dimension,
                                           storeURL: indexDir.appendingPathComponent("ThoughtSemanticV3/index.usearch"))
        do {
            try await usearch.loadFromDisk()
            index = usearch
        } catch {
            logger.notice("USearch 缓存不可用，降级重建：\(error.localizedDescription)")
            index = usearch
        }

        // 真身回填索引（磁盘缓存缺失或 key 映射为空时）
        await rebuildIndexIfEmpty(modelVersion: manifest?.activeModelVersion ?? ThoughtSemanticStore.defaultModelVersion)

        // 旧 JSON 向量一次性迁移（§22 Phase 2：校验成功后再标可清理）
        await migrateLegacyJSONStoreIfNeeded(into: semanticStore)

        // 挂 change feed
        await MainActor.run {
            ThoughtSemanticChangeFeed.shared.attach(store: semanticStore)
            ThoughtSemanticChangeFeed.shared.start()
        }
        logger.info("语义管线就绪")

        // 历史回填对账（2026-09-24 方案 §3 P0：此前首启从未回填，历史想法永远进不了索引；
        // 去重入队幂等，仅 index flag 开启时执行）。
        // P0-C（2026-09-27）：relation 开启也触发一次对账——reconcile 对已有向量的
        // 想法补入 relate 队列（存量补跑），解决「开 relation 后历史不动」。
        let indexOn = await MainActor.run { ThoughtSemanticFeatureFlags.index != .off }
        let relationOn = await MainActor.run { ThoughtSemanticFeatureFlags.relation != .off }
        if indexOn || relationOn {
            await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
        }

        // 队列节拍（§13.3）：flag off 时空转长睡眠；shadow/on 时每 30s 处理一小批
        startQueueHeartbeat()
    }

    /// 停节拍并释放索引/库引用（「删除设备智能索引」用）。销毁后可重新 bootstrap 重建。
    func shutdown() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let idx = index {
            try? await idx.destroy()
        }
        index = nil
        store = nil
        bootstrapped = false
        logger.notice("语义管线已停机（索引销毁或重建前调用）")
    }

    /// 立即处理一小批（设置页「继续/重试失败」后加速响应，不等 30s 节拍）。
    func kickQueue() async {
        guard let store, let index else { return }
        if heartbeatTask == nil {
            startQueueHeartbeat()
        }
        await ThoughtSemanticEmbeddingExecutor.shared.processBatch(store: store, index: index)
        await ThoughtSemanticRelateExecutor.shared.processBatch(store: store, index: index)
        await ThoughtAutomaticTopicDiscovery.shared.process(store: store, index: index)
    }

    private func startQueueHeartbeat() {
        guard let store, let index, heartbeatTask == nil else { return }
        heartbeatTask = Task {
            while !Task.isCancelled {
                let flag = await MainActor.run { ThoughtSemanticFeatureFlags.index }
                if flag != .off {
                    await ThoughtSemanticEmbeddingExecutor.shared.processBatch(store: store, index: index)
                }
                // relate 队列（P0-C）：独立 flag，与 embed 并列消费
                let relationFlag = await MainActor.run { ThoughtSemanticFeatureFlags.relation }
                if relationFlag != .off {
                    await ThoughtSemanticRelateExecutor.shared.processBatch(store: store, index: index)
                }
                await ThoughtAutomaticTopicDiscovery.shared.process(store: store, index: index)
                let anyActive = flag != .off || relationFlag != .off
                let interval: UInt64 = anyActive ? 30 : 300
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    /// 从 SQLite 真身重建索引（索引可丢弃，真身不可丢——方案 §8.2）。
    func rebuildIndexIfEmpty(modelVersion: String) async {
        guard let semanticStore = store, let idx = index else { return }
        let health = (try? await idx.validate()) ?? SemanticIndexHealth(entryCount: 0, isIntact: false, generation: 0, lastCheckpointAt: nil)
        guard health.entryCount == 0 || !health.isIntact else { return }
        do {
            let rows = try await semanticStore.loadAllActiveVectors(modelVersion: modelVersion)
            if let usearch = idx as? USearchSemanticIndex {
                try await usearch.rebuild(from: rows)
            } else if let flat = idx as? FlatSemanticIndex {
                let flatDim = rows.first?.vector.count ?? 0
                await flat.rebuild(from: rows.map { (id: $0.id, vector: $0.vector.map(Float16.init), dimension: flatDim) })
            }
            logger.info("索引重建完成 entries=\(rows.count)")
        } catch {
            logger.error("索引重建失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 旧 JSON 向量迁移（5000 条上限的 ThoughtEmbeddingStore）

    struct MigrationReport: Codable {
        var legacyEntries = 0
        var migrated = 0
        var skippedStale = 0    // contentHash 与当前正文不符（正文已改，待重新 embedding）
        var skippedExisting = 0 // 新库已有更新条目
    }

    /// 读取 thought-embeddings.json 真身，迁移到 SQLite。
    /// 迁移只增不删：原 JSON 文件保留（Phase 6 收尾时按方案统一清理）；
    /// 标记写 manifest.index_generation 侧字段外的 UserDefaults（简单一次标记）。
    func migrateLegacyJSONStoreIfNeeded(into semanticStore: ThoughtSemanticStore) async {
        let flagKey = "thoughtSemanticV3.legacyJSONMigrated"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let legacyDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThoughtAI", isDirectory: true)
        let fileURL = legacyDir.appendingPathComponent("thought-embeddings.json")
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([ThoughtEmbeddingEntry].self, from: data) else {
            UserDefaults.standard.set(true, forKey: flagKey) // 无旧文件也算完成
            return
        }

        var report = MigrationReport()
        report.legacyEntries = entries.count
        // 当前正文 hash（决定旧向量是否仍有效）
        var currentHashes: [UUID: String] = [:]
        await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            context.performAndWait {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "deletedAt == nil")
                let thoughts = (try? context.fetch(request)) ?? []
                for t in thoughts { currentHashes[t.id] = ThoughtSemanticText.contentHash( t.content) }
            }
        }

        do {
            for entry in entries {
                if try await semanticStore.hasActiveItem(thoughtID: entry.thoughtId,
                                                         contentHash: entry.contentHash,
                                                         modelVersion: entry.modelVersion) {
                    report.skippedExisting += 1
                    continue
                }
                // 旧条目 hash 与当前正文不符：不迁移（stale，feed 会重新入队）
                if let current = currentHashes[entry.thoughtId], current != entry.contentHash {
                    report.skippedStale += 1
                    continue
                }
                let vector = SemanticVectorMath.normalized(entry.vector.map(Float.init))
                let key = try await semanticStore.allocateVectorKey()
                let item = ThoughtSemanticStore.SemanticItem(
                    id: entry.thoughtId, contentHash: entry.contentHash, modelVersion: entry.modelVersion,
                    dimension: vector.count, vectorKey: key, state: "active", priority: 0,
                    lastAccessedAt: entry.updatedAt, updatedAt: Date())
                try await semanticStore.upsertItem(item, vector: vector.map(Float16.init))
                report.migrated += 1
            }
            UserDefaults.standard.set(true, forKey: flagKey)
            logger.info("旧 JSON 向量迁移完成 legacy=\(report.legacyEntries) migrated=\(report.migrated) stale=\(report.skippedStale) existing=\(report.skippedExisting)")
            // 迁移后重建索引
            await rebuildIndexIfEmpty(modelVersion: ThoughtSemanticStore.defaultModelVersion)
        } catch {
            logger.error("迁移中断（幂等，下次启动重试）：\(error.localizedDescription)")
        }
    }
}
