//
//  USearchSemanticIndex.swift
//  Holo
//
//  USearch HNSW 索引封装（语义图谱 V3 Phase 2 默认实现，方案 §8.1/ADR）
//
//  依赖 Vendor/USearch 2.26.2（固定版本，NumKong 已打 vendor 补丁）。
//  key 模型：USearch key = UInt64（vector_key），与 SQLite semantic_item 表
//  的 vector_key 列一一对应；UUID 映射由本类内存表 + SQLite 真身共同维护。
//  磁盘文件是加速缓存：load 失败/损坏时从 SQLite 真身重建，不丢用户数据。
//

import Foundation
import USearch

actor USearchSemanticIndex: LocalSemanticIndex {

    private var index: USearchIndex?
    private var keyToID: [UInt64: UUID] = [:]
    private var idToKey: [UUID: UInt64] = [:]
    private var nextKey: UInt64 = 1
    private let dimension: Int
    private let storeURL: URL?
    private var generation = 0
    private var lastCheckpoint: Date?

    /// - Parameters:
    ///   - dimension: 向量维度（如 1024，与后端 embeddings 模型一致）
    ///   - storeURL: 索引缓存文件位置；nil = 纯内存（测试/降级）
    init(dimension: Int, storeURL: URL? = nil) {
        self.dimension = dimension
        self.storeURL = storeURL
    }

    // MARK: - LocalSemanticIndex

    func upsert(id: UUID, vector: [Float], metadata: SemanticIndexMetadata) async throws {
        guard SemanticVectorMath.isNormalized(vector) else { throw LocalSemanticIndexError.notNormalized }
        guard vector.count == dimension else {
            throw LocalSemanticIndexError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        let idx = try ensureIndex()
        let key = try keyFor(id: id)
        try idx.remove(key: key)   // upsert 语义：同 key 先删后插
        try idx.add(key: key, vector: vector)
    }

    func remove(id: UUID) async throws {
        guard let key = idToKey[id], let idx = index else { return }
        try idx.remove(key: key)
        keyToID.removeValue(forKey: key)
        idToKey.removeValue(forKey: id)
    }

    func search(vector: [Float], topK: Int, filter: SemanticIndexFilter?) async throws -> [SemanticNeighbor] {
        guard SemanticVectorMath.isNormalized(vector) else { throw LocalSemanticIndexError.notNormalized }
        guard vector.count == dimension else {
            throw LocalSemanticIndexError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        guard let idx = index else { return [] }
        let excluded = filter?.excludedIDs ?? []
        // 多取一批以补偿被过滤掉的命中
        let fetch = excluded.isEmpty ? topK : topK + excluded.count
        let (keys, distances) = try idx.search(vector: vector, count: fetch)
        var out: [SemanticNeighbor] = []
        for (i, key) in keys.enumerated() {
            guard let id = keyToID[key], !excluded.contains(id) else { continue }
            // USearch .cos 度量返回距离（1 - cosine）；similarity = 1 - distance
            out.append(SemanticNeighbor(thoughtID: id, similarity: 1 - distances[i]))
            if out.count == topK { break }
        }
        return out
    }

    func checkpoint() async throws {
        guard let idx = index, let url = storeURL else { return }
        let dir = url.deletingLastPathComponent()
        // 临时 generation + 原子切换（方案 §8.2）
        let tmp = dir.appendingPathComponent("index-\(generation + 1).tmp.usearch")
        try? FileManager.default.removeItem(at: tmp)
        try idx.save(path: tmp.path)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        generation += 1
        lastCheckpoint = Date()
    }

    func validate() async throws -> SemanticIndexHealth {
        guard let idx = index else {
            return SemanticIndexHealth(entryCount: 0, isIntact: true, generation: generation, lastCheckpointAt: lastCheckpoint)
        }
        let count = Int(try idx.count)
        let intact = count == keyToID.count
        return SemanticIndexHealth(entryCount: count, isIntact: intact, generation: generation, lastCheckpointAt: lastCheckpoint)
    }

    func destroy() async throws {
        if let idx = index { try? idx.clear() }
        index = nil
        keyToID.removeAll()
        idToKey.removeAll()
        nextKey = 1
        generation += 1
        if let url = storeURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 持久化与重建

    /// 冷启动：尝试 load 磁盘缓存；失败抛错由调用方走 rebuild。
    func loadFromDisk() throws {
        guard let url = storeURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let idx = try USearchIndex.make(metric: .cos, dimensions: UInt32(dimension), connectivity: 16, quantization: .f16)
        do {
            try idx.load(path: url.path)
            index = idx
        } catch {
            // 损坏缓存直接丢弃，调用方从 SQLite 真身重建（方案 §8.2：不因索引损坏丢用户数据）
            index = nil
            try? FileManager.default.removeItem(at: url)
            throw LocalSemanticIndexError.corruptIndex(detail: "load 失败，缓存已清除待重建")
        }
    }

    /// 从 SQLite 真身重建映射与索引。
    func rebuild(from rows: [(id: UUID, key: UInt64, vector: [Float])]) throws {
        let idx = try USearchIndex.make(metric: .cos, dimensions: UInt32(dimension), connectivity: 16, quantization: .f16)
        try idx.reserve(UInt32(rows.count + 64))
        for row in rows {
            try idx.add(key: row.key, vector: row.vector)
            keyToID[row.key] = row.id
            idToKey[row.id] = row.key
            nextKey = max(nextKey, row.key + 1)
        }
        index = idx
        generation += 1
    }

    // MARK: - 私有

    private func ensureIndex() throws -> USearchIndex {
        if let idx = index { return idx }
        let idx = try USearchIndex.make(metric: .cos, dimensions: UInt32(dimension), connectivity: 16, quantization: .f16)
        try idx.reserve(UInt32(4096))
        index = idx
        return idx
    }

    private func keyFor(id: UUID) throws -> UInt64 {
        if let existing = idToKey[id] { return existing }
        let key = nextKey
        nextKey += 1
        idToKey[id] = key
        keyToID[key] = id
        return key
    }
}
