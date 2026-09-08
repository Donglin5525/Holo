//
//  HoloContextSemanticSearchRuntime.swift
//  Holo
//
//  通用个人情境的语义检索运行时接线（实施方案 §7.2 / 遗留缺口 B01）。
//
//  - 语义候选：HoloContextEmbeddingStore 本机向量缓存 + personal_context_embedding
//    通道；缓存缺失的条目按批重建（新记录首次规划时补齐，之后查询期只嵌一次原话）。
//  - 向量缓存键含内容摘要/模型/维度/策略版本/权限代际，任一变化即重建；
//    只存本机可丢弃缓存，不进 Core Data/CloudKit。
//  - 原文兜底：从检索入选条目的证据来源回查想法原文切段，供生成 prompt 引用。
//  - embedding 调用失败直接抛错 → 检索服务降级词法（degraded），不阻塞规划。
//

import Foundation

// MARK: - 向量调用窄协议

nonisolated struct HoloContextEmbeddingReply: Sendable, Equatable {
    let vectors: [[Double]]
    /// 模型族标识（缓存键组成部分）。
    let modelID: String
    /// 模型具体版本（后端换模型即变化 → 缓存全量重建）。
    let modelVersion: String
    let dimensions: Int
}

nonisolated protocol HoloContextEmbeddingCalling: Sendable {
    /// 个人情境向量必须走 personal_context_embedding purpose
    /// （新原文首次外发强制 moderation，不得借用 thought_embedding 的已审核假设）。
    func embedContextTexts(_ texts: [String]) async throws -> HoloContextEmbeddingReply
}

@MainActor
extension HoloBackendAIProvider: HoloContextEmbeddingCalling {
    func embedContextTexts(_ texts: [String]) async throws -> HoloContextEmbeddingReply {
        let response = try await embedWithMetadata(texts: texts, purpose: "personal_context_embedding")
        return HoloContextEmbeddingReply(
            vectors: response.vectors,
            modelID: "holo-backend",
            modelVersion: response.model,
            dimensions: response.dimensions
        )
    }
}

// MARK: - 向量缓存文件持久化

/// 本机受保护 JSON（与 ThoughtEmbeddingStore 同目录范式；损坏丢弃重建）。
nonisolated actor HoloContextEmbeddingFilePersistence: HoloContextEmbeddingPersisting {
    private let fileURL: URL
    private var cache: [HoloContextEmbeddingEntry]?
    private let queueLimit = 512

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ThoughtAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("context-embeddings.json")
    }

    func loadAll() async throws -> [HoloContextEmbeddingEntry] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([HoloContextEmbeddingEntry].self, from: data)
        else {
            cache = []
            return []
        }
        cache = entries
        return entries
    }

    func save(entries: [HoloContextEmbeddingEntry]) async throws {
        cache = entries
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .completeFileProtection)
    }
}

// MARK: - 语义候选提供方（运行时实现）

nonisolated struct HoloContextSemanticSearchProvider: HoloContextSemanticSearchProviding {
    /// 余弦门槛：低于视为不相关（text-embedding-v3 口径，相关经历 vs 规划请求普遍 ≥0.5）。
    static let defaultMatchThreshold = 0.45

    let embedding: any HoloContextEmbeddingCalling
    /// 已含 personalContext 的候选记录（与规划 recordsProvider 同源口径）。
    let recordsProvider: @Sendable () async throws -> [HoloMemoryRecord]
    let accessGenerationProvider: @Sendable () async -> Int
    let store: HoloContextEmbeddingStore
    let policyVersion: Int
    let threshold: Double
    let resultLimit: Int

    init(
        embedding: any HoloContextEmbeddingCalling,
        recordsProvider: @escaping @Sendable () async throws -> [HoloMemoryRecord],
        accessGenerationProvider: @escaping @Sendable () async -> Int,
        store: HoloContextEmbeddingStore = HoloContextEmbeddingStore(persistence: HoloContextEmbeddingFilePersistence()),
        policyVersion: Int = 1,
        threshold: Double = HoloContextSemanticSearchProvider.defaultMatchThreshold,
        resultLimit: Int = HoloContextRetrievalService.semanticOnlyReserve
    ) {
        self.embedding = embedding
        self.recordsProvider = recordsProvider
        self.accessGenerationProvider = accessGenerationProvider
        self.store = store
        self.policyVersion = policyVersion
        self.threshold = threshold
        self.resultLimit = resultLimit
    }

    enum SemanticSearchError: Error {
        case invalidQueryVector
        case embeddingModelMismatch
    }

    func semanticCandidateIDs(
        query: String,
        directions: [String]
    ) async throws -> [String: Double] {
        let candidates = HoloContextAccessPolicy.selectAdviceCandidates(
            records: try await recordsProvider()
        ).selected
        guard !candidates.isEmpty else { return [:] }

        // 查询文本：原话 + 检索方向，去重、钳制端点长度。
        var queryTexts: [String] = []
        for raw in [query] + directions {
            let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
            guard !text.isEmpty, !queryTexts.contains(text) else { continue }
            queryTexts.append(text)
        }
        guard !queryTexts.isEmpty else { return [:] }

        let queryReply = try await embedding.embedContextTexts(queryTexts)
        guard queryReply.vectors.count == queryTexts.count,
              queryReply.vectors.allSatisfy({ HoloContextEmbeddingStore.isValid($0, dimensions: queryReply.dimensions) })
        else { throw SemanticSearchError.invalidQueryVector }

        let accessGeneration = await accessGenerationProvider()

        // 候选向量：缓存命中优先，缺失批量重建（≤16 条/批）。
        var ids: [String] = []
        var vectors: [[Double]] = []
        var misses: [(recordID: String, payload: HoloPersonalContextPayloadV1, text: String)] = []
        for candidate in candidates {
            let text = Self.embeddingText(for: candidate.payload)
            if let cached = try await store.cachedVector(
                contextID: candidate.payload.contextID,
                sourceID: Self.primarySourceID(of: candidate.payload),
                text: text,
                modelID: queryReply.modelID,
                modelVersion: queryReply.modelVersion,
                dimensions: queryReply.dimensions,
                policyVersion: policyVersion,
                accessGeneration: accessGeneration
            ) {
                ids.append(candidate.recordID)
                vectors.append(cached)
            } else {
                misses.append((candidate.recordID, candidate.payload, text))
            }
        }

        for chunkStart in stride(from: 0, to: misses.count, by: 16) {
            let chunk = Array(misses[chunkStart..<min(chunkStart + 16, misses.count)])
            let reply = try await embedding.embedContextTexts(chunk.map(\.text))
            guard reply.dimensions == queryReply.dimensions, reply.modelVersion == queryReply.modelVersion else {
                throw SemanticSearchError.embeddingModelMismatch
            }
            var rebuilt: [HoloContextEmbeddingEntry] = []
            for (index, item) in chunk.enumerated() {
                let vector = reply.vectors[index]
                guard HoloContextEmbeddingStore.isValid(vector, dimensions: reply.dimensions) else { continue }
                ids.append(item.recordID)
                vectors.append(vector)
                rebuilt.append(HoloContextEmbeddingEntry(
                    cacheKey: HoloContextEmbeddingCacheKey.make(
                        contextID: item.payload.contextID,
                        sourceID: Self.primarySourceID(of: item.payload),
                        contentHash: HoloContextEmbeddingCacheKey.contentHash(of: item.text),
                        modelID: reply.modelID,
                        modelVersion: reply.modelVersion,
                        dimensions: reply.dimensions,
                        policyVersion: policyVersion,
                        accessGeneration: accessGeneration
                    ),
                    contextID: item.payload.contextID,
                    sourceID: Self.primarySourceID(of: item.payload),
                    contentHash: HoloContextEmbeddingCacheKey.contentHash(of: item.text),
                    modelID: reply.modelID,
                    modelVersion: reply.modelVersion,
                    dimensions: reply.dimensions,
                    policyVersion: policyVersion,
                    accessGeneration: accessGeneration,
                    vector: vector,
                    createdAt: Date()
                ))
            }
            // 缓存写失败只影响下次命中，不影响本轮排序结果。
            if !rebuilt.isEmpty {
                _ = try? await store.store(entries: rebuilt, now: Date())
            }
        }

        return HoloContextEmbeddingStore.rank(
            candidateVectors: Array(zip(ids, vectors).map { (id: $0, vector: $1) }),
            queryVectors: queryReply.vectors,
            threshold: threshold,
            limit: resultLimit
        )
    }

    /// 嵌入文本：命题 + 关系描述（与词法召回同一文本口径）。
    static func embeddingText(for payload: HoloPersonalContextPayloadV1) -> String {
        let text = payload.statement + " " + payload.relationText
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }

    private static func primarySourceID(of payload: HoloPersonalContextPayloadV1) -> String {
        payload.basis.first?.sourceID ?? "ctx-\(payload.contextID)"
    }
}

// MARK: - 原文兜底（想法来源）

/// 从检索入选条目的证据来源回查想法原文，切段交给生成 prompt（预算由协调器钳制）。
@MainActor
struct HoloContextThoughtRawFallbackProvider: HoloContextRawFallbackProviding {
    /// 回查的证据来源上限（段数/字符预算另由协调器钳制）。
    static let sourceLimit = 4

    let repository: ThoughtRepository

    func rawSegments(
        for result: HoloContextRetrievalResult,
        frame: HoloPlanningRequestFrame
    ) async throws -> [HoloContextSegment] {
        var sourceIDs: [String] = []
        for entry in result.entries {
            for basis in entry.payload.basis where !sourceIDs.contains(basis.sourceID) {
                sourceIDs.append(basis.sourceID)
            }
            if sourceIDs.count >= Self.sourceLimit { break }
        }

        var segments: [HoloContextSegment] = []
        for sourceID in sourceIDs {
            guard let uuid = UUID(uuidString: sourceID),
                  let thought = try? repository.fetchById(uuid) else { continue }
            let snapshot = HoloContextSourceSnapshot(
                sourceID: sourceID,
                sourceDomain: "thought",
                sourceKind: "userNote",
                revisionDigest: HoloThoughtContextSourcePaging.revisionDigest(thought),
                sourceCreatedAt: thought.createdAt,
                sourceUpdatedAt: thought.updatedAt,
                plainText: HoloContextPlainTextNormalizer.normalize(thought.content).plainText,
                sensitivity: .normal,
                accessGeneration: 1
            )
            segments.append(contentsOf: HoloContextSegmenter.segments(for: snapshot))
        }
        return segments
    }
}
