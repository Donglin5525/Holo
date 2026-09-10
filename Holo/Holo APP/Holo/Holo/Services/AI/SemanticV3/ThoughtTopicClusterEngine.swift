//
//  ThoughtTopicClusterEngine.swift
//  Holo
//
//  新脉络候选簇引擎（语义图谱 V3 Phase 5，方案 §4.4/§5.2）
//
//  把「互相相近、又不属于任何主题」的想法聚成候选簇：每条想法 ANN 找近邻
//  （相似度 ≥ 校准召回阈值），并查集连通分量成簇；簇成员 ≥3 才够格。
//  聚类核心是纯函数（邻接查询单测可注入）；落库走 candidate_cluster 表，
//  同 fingerprint 记住冷却与拒绝：以后再说=30 天冷却（簇新增 2 条有效想法
//  提前解除），不再建议=fingerprint 永久 tombstone。
//  shadow 纪律：引擎只落库不展示；建议卡由 discovery flag(.on) 的 UI 消费。
//

import CoreData
import CryptoKit
import Foundation
import OSLog

enum ThoughtTopicClusterEngine {

    /// 与 verifier/摘要客户端同源版本串（复制而非引用，保持本文件 standalone 可编译）
    static let engineVersion = "thought_semantic_v3.0"
    private static let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtTopicCluster")

    /// 簇最小成员数（攒够同类想法才建议；空态文案口径）
    static let minClusterSize = 3
    /// 近邻搜索宽度（每条想法最多拉 8 个近邻建边）
    private static let neighborTopK = 8
    /// 发现节流（6 小时内不重跑）
    private static let throttleInterval: TimeInterval = 6 * 3_600
    private static let throttleKey = "thought_semantic_v3_last_cluster_discovery"
    /// 「以后再说」冷却天数（§4.4）
    static let snoozeDays = 30
    /// 冷却提前解除：簇新增有效想法数
    static let snoozeEscapeNewMembers = 2

    // MARK: - 纯函数核心（单测可注入邻接查询）

    /// 并查集连通分量。neighborLookup 返回「该想法的近邻（含相似度，已过滤到孤儿集合内）」。
    static func clusterComponents(ids: [UUID],
                                  vectors: [UUID: [Float]],
                                  threshold: Float,
                                  minSize: Int,
                                  neighborLookup: (UUID) -> [(id: UUID, similarity: Float)]) -> [(members: [UUID], cohesion: Float)] {
        guard ids.count >= minSize else { return [] }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var parent = Array(0..<ids.count)

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var cur = x
            while parent[cur] != root { let next = parent[cur]; parent[cur] = root; cur = next }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        // 边先收集（canonical pair 去重），并查集全量合并后再按最终根聚合内聚度——
        // 若在合并过程中按当时根累计，后续合并会让旧根失效丢权重
        var edges: [(Int, Int, Float)] = []
        var seenPairs = Set<UInt64>()
        for id in ids {
            guard let vector = vectors[id], let i = indexByID[id] else { continue }
            for neighbor in neighborLookup(id) where neighbor.id != id {
                guard let j = indexByID[neighbor.id], vectors[neighbor.id] != nil else { continue }
                guard neighbor.similarity >= threshold else { continue }
                let a = min(i, j), b = max(i, j)
                let pairKey = UInt64(a) << 32 | UInt64(b)
                guard !seenPairs.contains(pairKey) else { continue }
                seenPairs.insert(pairKey)
                union(i, j)
                edges.append((i, j, neighbor.similarity))
            }
        }

        var byRoot: [Int: [UUID]] = [:]
        for id in ids {
            guard let idx = indexByID[id] else { continue }
            byRoot[find(idx), default: []].append(id)
        }
        var agg: [Int: (sum: Float, count: Int)] = [:]
        for (i, _, similarity) in edges {
            let root = find(i)
            let prev = agg[root] ?? (0, 0)
            agg[root] = (prev.sum + similarity, prev.count + 1)
        }
        return byRoot.values.compactMap { members in
            guard members.count >= minSize, let firstIdx = indexByID[members[0]] else { return nil }
            let root = find(firstIdx)
            let (sum, count) = agg[root] ?? (0, 0)
            // 孤立簇（无内部边）不该出现——成簇必有边；防御口径取阈值本身
            let cohesion = count > 0 ? sum / Float(count) : threshold
            return (members.sorted { $0.uuidString < $1.uuidString }, cohesion)
        }
        .sorted { ($0.members.count, $1.cohesion) < ($1.members.count, $0.cohesion) }
    }

    // MARK: - fingerprint

    static func fingerprint(memberIDs: [UUID]) -> String {
        let canonical = memberIDs.map(\.uuidString).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8) + Data(engineVersion.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 发现入口（主题页触发；节流 6h）

    /// 孤儿想法 = 有向量且投影上无 active 主题。返回是否真的跑了（供日志/测试）。
    @discardableResult
    static func discoverIfNeeded(context: NSManagedObjectContext,
                                 store: ThoughtSemanticStore,
                                 index: any LocalSemanticIndex,
                                 modelVersion: String) async throws -> Bool {
        let last = UserDefaults.standard.double(forKey: throttleKey)
        guard Date().timeIntervalSince1970 - last >= throttleInterval else { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
        try await discover(context: context, store: store, index: index, modelVersion: modelVersion)
        return true
    }

    static func discover(context: NSManagedObjectContext,
                         store: ThoughtSemanticStore,
                         index: any LocalSemanticIndex,
                         modelVersion: String) async throws {
        let threshold = ThoughtSemanticCalibration.current().config.recallMinCosine

        // 孤儿集合：全量想法中投影无 active 主题、且在本机语义库有向量的
        let request = Thought.fetchRequest()
        request.fetchBatchSize = 200
        let all = try ManagedObjectContextCompat.fetch(request, in: context)
        var orphanIDs: [UUID] = []
        for thought in all where !thought.isSoftDeleted {
            if ThoughtTopicLinkProjection.effectiveTopics(for: thought).isEmpty {
                orphanIDs.append(thought.id)
            }
        }
        guard orphanIDs.count >= minClusterSize else { return }
        let vectorRows = try await store.loadAllActiveVectors(modelVersion: modelVersion)
        let vectorByID = Dictionary(vectorRows.map { ($0.id, $0.vector) }, uniquingKeysWith: { first, _ in first })
        let orphans = orphanIDs.filter { vectorByID[$0] != nil }
        guard orphans.count >= minClusterSize else { return }

        let orphanSet = Set(orphans)
        let vectors = orphans.reduce(into: [UUID: [Float]]()) { $0[$1] = vectorByID[$1] }

        // 先异步预取全部近邻边（ANN 只在孤儿集合内建边），再跑同步纯函数聚类
        var adjacency: [UUID: [(id: UUID, similarity: Float)]] = [:]
        for id in orphans {
            guard let vector = vectors[id] else { continue }
            let neighbors = (try? await index.search(vector: vector, topK: neighborTopK + 1, filter: nil)) ?? []
            adjacency[id] = neighbors
                .filter { orphanSet.contains($0.thoughtID) }
                .map { (id: $0.thoughtID, similarity: $0.similarity) }
        }
        let components = clusterComponents(ids: orphans, vectors: vectors, threshold: threshold,
                                           minSize: minClusterSize) { id in
            adjacency[id] ?? []
        }
        guard !components.isEmpty else { return }
        try await persist(components: components, store: store)
    }

    /// 落库纪律（§4.4）：同一时间最多一张建议卡；拒绝/已转换的 fingerprint 永久跳过；
    /// 冷却中的簇只有新增 ≥2 条有效想法才提前解除；其余合格簇存 ready 备选。
    private static func persist(components: [(members: [UUID], cohesion: Float)],
                                store: ThoughtSemanticStore) async throws {
        let now = Date()
        var suggestedUsed = false
        for component in components {
            let fp = fingerprint(memberIDs: component.members)
            let existing = try await store.loadCluster(byFingerprint: fp)
            switch existing?.state {
            case "rejected", "converted":
                continue
            case "snoozed":
                let dismissedUntil = existing?.dismissedUntil ?? .distantFuture
                let escaped = component.members.count >= (existing?.memberIDs.count ?? 0) + snoozeEscapeNewMembers
                if dismissedUntil > now, !escaped { continue }
            default:
                break
            }
            let id = existing?.id ?? UUID().uuidString.lowercased()
            if !suggestedUsed {
                try await store.upsertCluster(id: id, fingerprint: fp, memberIDs: component.members,
                                              state: "suggested", cohesion: component.cohesion,
                                              dismissedUntil: nil)
                suggestedUsed = true
            } else {
                try await store.upsertCluster(id: id, fingerprint: fp, memberIDs: component.members,
                                              state: "ready", cohesion: component.cohesion,
                                              dismissedUntil: existing?.dismissedUntil)
            }
        }
    }
}
