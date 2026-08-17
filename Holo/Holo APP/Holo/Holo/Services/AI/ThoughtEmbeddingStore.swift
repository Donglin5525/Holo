//
//  ThoughtEmbeddingStore.swift
//  Holo
//
//  P2（方案 §5.3）：想法向量本机存储。
//  范式对齐 V3 缓存设计（ThoughtRelationCacheStore/HealthInsightCache）：受保护 JSON、
//  指纹去重、modelVersion 隔离、LRU、损坏丢弃重建；不进 Core Data/CloudKit、不外发。
//  V3 ADR-002：不引入向量数据库，千条规模端侧余弦暴力扫描（<10ms 量级）。
//

import Foundation
import CryptoKit

struct ThoughtEmbeddingEntry: Codable, Sendable {
    let thoughtId: UUID
    /// 规范化正文的 SHA-256 前缀；正文变化即需重算
    let contentHash: String
    /// embedding 模型版本；版本变更全量重算
    let modelVersion: String
    let vector: [Double]
    let updatedAt: Date
}

actor ThoughtEmbeddingStore {

    static let shared = ThoughtEmbeddingStore()
    static let maxEntries = 5000
    /// 模型版本标识（后端换 embedding 模型时同步改此值触发全量重算）
    static let modelVersion = "text-embedding-v3-v1"

    private let fileURL: URL
    private var entries: [UUID: ThoughtEmbeddingEntry] = [:]
    private var loaded = false

    /// - Parameter directory: 落盘目录（默认与反馈事件同目录；测试注入临时目录）
    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ThoughtAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("thought-embeddings.json")
    }

    // MARK: - 读写

    func entry(for thoughtId: UUID) -> ThoughtEmbeddingEntry? {
        loadIfNeeded()
        return entries[thoughtId]
    }

    func upsert(_ entry: ThoughtEmbeddingEntry) {
        loadIfNeeded()
        entries[entry.thoughtId] = entry
        if entries.count > Self.maxEntries {
            // LRU：淘汰最旧更新时间
            let oldest = entries.values.sorted { $0.updatedAt < $1.updatedAt }
                .prefix(entries.count - Self.maxEntries)
            for item in oldest { entries[item.thoughtId] = nil }
        }
        persist()
    }

    /// 该想法是否需要（重）生成向量：无记录 / 正文变化 / 模型版本变更
    func needsEmbedding(thoughtId: UUID, contentHash: String) -> Bool {
        loadIfNeeded()
        guard let entry = entries[thoughtId] else { return true }
        return entry.contentHash != contentHash || entry.modelVersion != Self.modelVersion
    }

    /// 端侧余弦 Top-K 近邻（暴力扫描，千条规模 <10ms）
    func topNeighbors(of vector: [Double], excluding excludedId: UUID, limit: Int = 5) -> [(thoughtId: UUID, cosine: Double)] {
        loadIfNeeded()
        var scored: [(UUID, Double)] = []
        for (id, entry) in entries where id != excludedId && entry.vector.count == vector.count {
            scored.append((id, Self.cosine(entry.vector, vector)))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { (thoughtId: $0.0, cosine: $0.1) }
    }

    func allEntries() -> [ThoughtEmbeddingEntry] {
        loadIfNeeded()
        return Array(entries.values)
    }

    func count() -> Int {
        loadIfNeeded()
        return entries.count
    }

    /// 删除账户数据时调用
    func destroy() {
        entries = [:]
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Helpers

    static func contentHash(of text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0, lNorm = 0.0, rNorm = 0.0
        for i in 0..<lhs.count {
            dot += lhs[i] * rhs[i]
            lNorm += lhs[i] * lhs[i]
            rNorm += rhs[i] * rhs[i]
        }
        guard lNorm > 0, rNorm > 0 else { return 0 }
        return dot / ((lNorm * rNorm).squareRoot())
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ThoughtEmbeddingEntry].self, from: data) else {
            return  // 文件缺失/损坏：从空开始重建
        }
        entries = Dictionary(decoded.map { ($0.thoughtId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(entries.values)) else { return }
        try? data.write(to: fileURL, options: .completeFileProtection)
    }
}
