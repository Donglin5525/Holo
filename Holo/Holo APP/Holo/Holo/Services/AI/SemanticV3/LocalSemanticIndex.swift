//
//  LocalSemanticIndex.swift
//  Holo
//
//  本地向量索引协议（语义图谱 V3 Phase 2，方案 §8.1）
//
//  核心约定：
//  1. 向量只做候选召回，永不直接决定用户可见关系（方案核心不变量 2）。
//  2. SQLite 元数据库（ThoughtSemanticStore）是向量真身与唯一事实源；
//     索引（无论 USearch 还是 flat）都是可丢弃、可重建的加速结构。
//  3. 实现方必须线程安全（推荐 actor 化）；损坏时抛错，由上层从真身重建。
//

import Foundation

/// 索引条目元数据（与 semantic_item 表对应）
struct SemanticIndexMetadata: Codable, Equatable {
    var thoughtID: UUID
    var contentHash: String
    var modelVersion: String
    var dimension: Int
}

/// 检索过滤（排除已拒绝 pair、已删除对象等）
struct SemanticIndexFilter: Codable, Equatable {
    var excludedIDs: Set<UUID> = []
    public init(excludedIDs: Set<UUID> = []) { self.excludedIDs = excludedIDs }
}

/// 近邻结果（similarity = cosine 相似度，向量已 L2 归一化）
struct SemanticNeighbor: Codable, Equatable {
    var thoughtID: UUID
    var similarity: Float
}

/// 索引健康度
struct SemanticIndexHealth: Codable, Equatable {
    var entryCount: Int
    var isIntact: Bool
    var generation: Int
    var lastCheckpointAt: Date?
}

enum LocalSemanticIndexError: Error {
    case dimensionMismatch(expected: Int, got: Int)
    case corruptIndex(detail: String)
    case notNormalized            // 向量必须 L2 归一化
}

/// 本地向量索引协议（方案 §8.1）。默认实现 USearchSemanticIndex（HNSW），
/// fallback 为 FlatSemanticIndex（Float16 + Accelerate 分块扫描）。
/// 两者都必须通过 50k/100k 性能门禁（ADR 见方案同目录）。
protocol LocalSemanticIndex: Actor {

    /// 插入或更新一条向量（同 thoughtID 覆盖旧向量——正文版本升级路径）。
    func upsert(id: UUID, vector: [Float], metadata: SemanticIndexMetadata) async throws

    /// tombstone 删除；空闲时由 compact 物理清除。
    func remove(id: UUID) async throws

    /// top-K 近邻检索（余弦相似度，向量需已归一化）。
    func search(vector: [Float], topK: Int, filter: SemanticIndexFilter?) async throws -> [SemanticNeighbor]

    /// 持久化落盘（USearch 实现为索引文件；flat 实现为 no-op，真身在 SQLite）。
    func checkpoint() async throws

    /// 完整性校验（计数比对 + 抽样检索）。
    func validate() async throws -> SemanticIndexHealth

    /// 销毁全部索引数据（「删除设备智能索引」入口与模型升级旧代清理共用）。
    func destroy() async throws
}

// MARK: - 向量工具（两种实现共用）

nonisolated enum SemanticVectorMath {

    /// L2 归一化；零向量原样返回（调用方应跳过不可归一化向量）。
    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    static func isNormalized(_ v: [Float], tolerance: Float = 0.01) -> Bool {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return abs(n - 1) < tolerance
    }

    /// cosine 相似度（两向量均需归一化；直接点积）
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }
}
