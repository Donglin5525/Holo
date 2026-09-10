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

    /// 冷启动装配。App 启动后台调用一次（幂等）。
    func bootstrap(root: URL? = nil) async {
        guard !bootstrapped else { return }
        bootstrapped = true

        let semanticStore = await ThoughtSemanticStore(root: root)
        do {
            try await semanticStore.open()
        } catch {
            logger.error("语义库打开失败，本会话禁用语义索引：\(error.localizedDescription)")
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
                for t in thoughts { currentHashes[t.id] = ThoughtEmbeddingStore.contentHash(of: t.content) }
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
