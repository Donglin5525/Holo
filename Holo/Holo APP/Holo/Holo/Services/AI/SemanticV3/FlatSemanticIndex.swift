//
//  FlatSemanticIndex.swift
//  Holo
//
//  Float16 + Accelerate 分块扫描索引（语义图谱 V3 Phase 2，方案 §8.1 fallback）
//
//  定位：USearch spike 未过门禁或运行期异常时的降级实现。真身在 SQLite
//  （ThoughtSemanticStore），本索引为纯内存加速结构：冷启动从真身回填，
//  checkpoint 为 no-op。同样必须通过 50k/100k 门禁（模拟器实测见实施日志）。
//

import Accelerate
import Foundation

actor FlatSemanticIndex: LocalSemanticIndex {

    private struct Entry {
        let id: UUID
        let vector: [Float16]     // 归一化向量以 Float16 存储（方案 §8.2）
    }

    private var entries: [Entry] = []
    private var dimension: Int = 0
    private var generation = 0
    private let chunkSize = 2048  // 分块矩阵化扫描，控制单次 vDSP 调用规模

    // MARK: - LocalSemanticIndex

    func upsert(id: UUID, vector: [Float], metadata: SemanticIndexMetadata) async throws {
        guard SemanticVectorMath.isNormalized(vector) else { throw LocalSemanticIndexError.notNormalized }
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension else {
            throw LocalSemanticIndexError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        removeLocked(id: id)
        entries.append(Entry(id: id, vector: vector.map(Float16.init)))
    }

    func remove(id: UUID) async throws {
        removeLocked(id: id)
    }

    func search(vector: [Float], topK: Int, filter: SemanticIndexFilter?) async throws -> [SemanticNeighbor] {
        guard SemanticVectorMath.isNormalized(vector) else { throw LocalSemanticIndexError.notNormalized }
        guard !entries.isEmpty else { return [] }
        guard vector.count == dimension else {
            throw LocalSemanticIndexError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        let excluded = filter?.excludedIDs ?? []

        // 分块扫描：每块转 Float32 连续缓冲，vDSP 矩阵点积
        var best: [(UUID, Float)] = []
        var start = 0
        while start < entries.count {
            let end = min(start + chunkSize, entries.count)
            let chunk = entries[start..<end]

            // 展平为行优先矩阵 [chunk × dim]
            var flat = [Float](repeating: 0, count: chunk.count * dimension)
            for (r, entry) in chunk.enumerated() {
                for c in 0..<dimension {
                    flat[r * dimension + c] = Float(entry.vector[c])
                }
            }
            // scores = flat × query（vDSP 矩阵-向量积）
            var scores = [Float](repeating: 0, count: chunk.count)
            vDSP_mmul(flat, 1, vector, 1, &scores, 1, vDSP_Length(chunk.count), 1, vDSP_Length(dimension))

            for (i, entry) in chunk.enumerated() where !excluded.contains(entry.id) {
                best.append((entry.id, scores[i]))
            }
            start = end
        }

        return best.sorted { $0.1 > $1.1 }.prefix(topK)
            .map { SemanticNeighbor(thoughtID: $0.0, similarity: $0.1) }
    }

    func checkpoint() async throws {
        // no-op：向量真身在 ThoughtSemanticStore（SQLite），索引可随时从真身重建
    }

    func validate() async throws -> SemanticIndexHealth {
        SemanticIndexHealth(entryCount: entries.count, isIntact: true, generation: generation, lastCheckpointAt: nil)
    }

    func destroy() async throws {
        entries.removeAll(keepingCapacity: false)
        dimension = 0
        generation += 1
    }

    // MARK: - 真身回填（冷启动）

    /// 从 SQLite 真身批量回填（ThoughtSemanticStore 冷启动通道）。
    func rebuild(from rows: [(id: UUID, vector: [Float16], dimension: Int)]) {
        entries = rows.map { Entry(id: $0.id, vector: $0.vector) }
        dimension = rows.first?.dimension ?? 0
        generation += 1
    }

    private func removeLocked(id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries.remove(at: idx)
        }
    }
}
