//
//  HoloContextEmbeddingStore.swift
//  Holo
//
//  通用个人情境的向量缓存（实施方案 §7.2）。
//
//  - 缓存键含 context/contentHash/模型 ID/模型版本/维度/policyVersion/accessGeneration——
//    任一变化即失效，不污染 ThoughtEmbeddingStore 的 thoughtId 空间。
//  - 返回数量、有限数值、非零范数、维度与模型版本全部验证；不匹配候选先排除再重建。
//  - 仅本机受保护缓存：可丢弃重建、不进 CloudKit；淘汰保留覆盖指标。
//  - 首版 5,000 条分段向量上限；超过后结合词法召回，不宣称资料不存在。
//
//  持久化经协议注入；纯逻辑可 standalone 编译。
//

import Foundation

// MARK: - 缓存条目与键

nonisolated struct HoloContextEmbeddingEntry: Codable, Equatable, Sendable {
    var cacheKey: String
    var contextID: String
    var sourceID: String
    var contentHash: String
    var modelID: String
    var modelVersion: String
    var dimensions: Int
    var policyVersion: Int
    var accessGeneration: Int
    var vector: [Double]
    var createdAt: Date
}

/// 不可变缓存键：程序拼接，模型不参与。
nonisolated enum HoloContextEmbeddingCacheKey {
    static func make(
        contextID: String,
        sourceID: String,
        contentHash: String,
        modelID: String,
        modelVersion: String,
        dimensions: Int,
        policyVersion: Int,
        accessGeneration: Int
    ) -> String {
        "pc-emb|\(contextID)|\(sourceID)|\(contentHash)|\(modelID)|\(modelVersion)|\(dimensions)|\(policyVersion)|\(accessGeneration)"
    }

    /// 内容稳定摘要（与抑制键同族散列）。
    static func contentHash(of text: String) -> String {
        HoloContextSuppressionKeys.stableDigest(text)
    }
}

// MARK: - 持久化协议

/// 本机受保护缓存的读写（文件/Keychain 实现在接线层；测试用内存实现）。
nonisolated protocol HoloContextEmbeddingPersisting: Sendable {
    func loadAll() async throws -> [HoloContextEmbeddingEntry]
    func save(entries: [HoloContextEmbeddingEntry]) async throws
}

/// 内存实现（standalone 测试用）。
nonisolated actor HoloContextInMemoryEmbeddingPersistence: HoloContextEmbeddingPersisting {
    private var entries: [HoloContextEmbeddingEntry] = []

    func loadAll() async throws -> [HoloContextEmbeddingEntry] { entries }

    func save(entries: [HoloContextEmbeddingEntry]) async throws {
        self.entries = entries
    }
}

// MARK: - 覆盖指标

nonisolated struct HoloContextEmbeddingCoverage: Codable, Equatable, Sendable {
    var cachedEntries = 0
    var capacityLimit = 0
    var evictedCount = 0
    var invalidatedByGeneration = 0
    var rebuiltCount = 0

    var isAtCapacity: Bool { capacityLimit > 0 && cachedEntries >= capacityLimit }
}

// MARK: - Store

nonisolated struct HoloContextEmbeddingStore: Sendable {
    /// 首版分段向量上限（§7.2）。
    static let capacityLimit = 5_000

    let persistence: any HoloContextEmbeddingPersisting

    init(persistence: any HoloContextEmbeddingPersisting) {
        self.persistence = persistence
    }

    // MARK: 查询

    /// 命中查询：键完全一致才可用（版本/维度/代际任一变化视为未命中）。
    func cachedVector(
        contextID: String,
        sourceID: String,
        text: String,
        modelID: String,
        modelVersion: String,
        dimensions: Int,
        policyVersion: Int,
        accessGeneration: Int
    ) async throws -> [Double]? {
        let key = HoloContextEmbeddingCacheKey.make(
            contextID: contextID,
            sourceID: sourceID,
            contentHash: HoloContextEmbeddingCacheKey.contentHash(of: text),
            modelID: modelID,
            modelVersion: modelVersion,
            dimensions: dimensions,
            policyVersion: policyVersion,
            accessGeneration: accessGeneration
        )
        let entries = try await persistence.loadAll()
        guard let entry = entries.first(where: { $0.cacheKey == key }) else { return nil }
        return Self.isValid(entry.vector, dimensions: dimensions) ? entry.vector : nil
    }

    // MARK: 写入

    struct StoreResult: Equatable, Sendable {
        var coverage: HoloContextEmbeddingCoverage
        var evictedCount: Int
    }

    /// 写入新向量（先清同 contextID 的旧版本条目，再容量淘汰最旧）。
    func store(
        entries newEntries: [HoloContextEmbeddingEntry],
        now: Date
    ) async throws -> StoreResult {
        var entries = try await persistence.loadAll()
        let newContextIDs = Set(newEntries.map(\.contextID))
        entries.removeAll { newContextIDs.contains($0.contextID) }
        var evicted = 0
        for entry in newEntries where Self.isValid(entry.vector, dimensions: entry.dimensions) {
            entries.append(entry)
        }
        if entries.count > Self.capacityLimit {
            let overflow = entries.count - Self.capacityLimit
            // 最旧先淘汰。
            entries.sort { $0.createdAt < $1.createdAt }
            entries.removeFirst(overflow)
            evicted = overflow
        }
        try await persistence.save(entries: entries)
        var coverage = HoloContextEmbeddingCoverage()
        coverage.cachedEntries = entries.count
        coverage.capacityLimit = Self.capacityLimit
        coverage.evictedCount = evicted
        return StoreResult(coverage: coverage, evictedCount: evicted)
    }

    // MARK: 失效

    /// 来源删除/修改：清关联条目（返回清除数）。
    func invalidate(sourceIDs: [String]) async throws -> Int {
        let ids = Set(sourceIDs)
        var entries = try await persistence.loadAll()
        let before = entries.count
        entries.removeAll { ids.contains($0.sourceID) }
        try await persistence.save(entries: entries)
        return before - entries.count
    }

    /// 权限代际变化：全部失效（用户清空/遗忘后不得复用旧向量）。
    func invalidateAll() async throws {
        try await persistence.save(entries: [])
    }

    // MARK: 校验

    /// 向量合法性：非空、维度一致、数值有限、范数非零。
    static func isValid(_ vector: [Double], dimensions: Int) -> Bool {
        guard vector.count == dimensions, dimensions > 0 else { return false }
        var normSquared = 0.0
        for value in vector {
            guard value.isFinite else { return false }
            normSquared += value * value
        }
        return normSquared > 0
    }

    /// 余弦相似度（同维度合法向量；非法输入返回 nil）。
    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            guard lhs[index].isFinite, rhs[index].isFinite else { return nil }
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }

    // MARK: 多查询向量排序（纯逻辑）

    /// 候选与多查询向量取最大余弦，低于阈值的剔除；返回 id → 分数（降序截断 limit）。
    /// 同分按 id 升序保证确定性；非法向量（维度不符/非有限/零范数）不参与。
    static func rank(
        candidateVectors: [(id: String, vector: [Double])],
        queryVectors: [[Double]],
        threshold: Double,
        limit: Int
    ) -> [String: Double] {
        guard !queryVectors.isEmpty, limit > 0 else { return [:] }
        var scored: [(id: String, score: Double)] = []
        for candidate in candidateVectors {
            var best = Double.nan
            for query in queryVectors {
                if let cosine = cosineSimilarity(candidate.vector, query), cosine.isFinite,
                   best.isNaN || cosine > best {
                    best = cosine
                }
            }
            guard let score = best.isFinite ? best : Optional<Double>.none, score >= threshold else { continue }
            scored.append((candidate.id, score))
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        var result: [String: Double] = [:]
        for entry in scored.prefix(limit) {
            result[entry.id] = entry.score
        }
        return result
    }
}
