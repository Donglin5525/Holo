//
//  ThoughtSemanticCandidateEngine.swift
//  Holo
//
//  P2（方案 §5.1/§5.3）：embedding 语义候选召回引擎。
//  V3 教训全量适用：向量只做候选召回输入（semanticNeighborTags），永不直接决定
//  用户可见结果；最终判断仍是受控 LLM + 端侧白名单校验。
//  flag 三档：off（不计算）/ shadow（计算并记录、不注入）/ inject（注入 payload）。
//

import Foundation
import os.log

// ThoughtSemanticCandidateMode 定义在 ThoughtClassificationFeedbackStore.swift（独立可编译）

@MainActor
enum ThoughtSemanticCandidateEngine {

    private static let logger = Logger(subsystem: "com.holo.app", category: "ThoughtSemanticCandidates")

    /// 邻居想法认可标签的注入上限（prompt 语义候选 ≤8 个）
    static let maxNeighborTags = 8
    /// 近邻想法数
    static let neighborLimit = 5
    /// 有效向量的最低余弦（太远的邻居没有参考意义，避免噪声）
    static let minimumCosine = 0.3

    // MARK: - 生成链路（分类成功后触发，静默失败不阻塞）

    /// 确保想法有可用向量（hash 未变则跳过）；失败只记日志
    static func ensureEmbedded(thoughtId: UUID) async {
        guard ThoughtSemanticCandidateMode.current != .off else { return }
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else { return }

        let repository = ThoughtRepository()
        guard let thought = try? repository.fetchByIdInternal(thoughtId),
              !thought.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let normalized = String(thought.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        let hash = ThoughtEmbeddingStore.contentHash(of: normalized)
        guard await ThoughtEmbeddingStore.shared.needsEmbedding(thoughtId: thoughtId, contentHash: hash) else { return }

        do {
            let provider = HoloBackendAIProvider()
            let vectors = try await provider.embed(texts: [normalized])
            guard let vector = vectors.first, !vector.isEmpty else { return }
            await ThoughtEmbeddingStore.shared.upsert(ThoughtEmbeddingEntry(
                thoughtId: thoughtId,
                contentHash: hash,
                modelVersion: ThoughtEmbeddingStore.modelVersion,
                vector: vector,
                updatedAt: Date()
            ))
            logger.info("语义向量已生成：\(thoughtId)")
        } catch {
            // 静默重试语义：下一次分类/回填再补；不阻塞分类链路
            logger.info("语义向量生成失败（将择机重试）：\(error.localizedDescription)")
        }
    }

    // MARK: - 候选召回（payload 组装前调用）

    struct SemanticCandidates {
        /// 注入 payload 的近邻认可标签（≤8）
        let neighborTags: [String]
        /// 近邻明细（Debug/评估用）
        let neighbors: [(thoughtId: UUID, cosine: Double)]
    }

    /// 计算当前想法的语义候选标签。mode == off 时返回 nil（不计算）；
    /// shadow 时调用方仅记录不注入；inject 时进 payload。
    static func candidates(for thoughtId: UUID, content: String) async -> SemanticCandidates? {
        let mode = ThoughtSemanticCandidateMode.current
        guard mode != .off else { return nil }
        guard let vector = await currentVector(thoughtId: thoughtId, content: content) else { return nil }

        let neighbors = await ThoughtEmbeddingStore.shared.topNeighbors(
            of: vector,
            excluding: thoughtId,
            limit: neighborLimit
        ).filter { $0.cosine >= minimumCosine }
        guard !neighbors.isEmpty else { return SemanticCandidates(neighborTags: [], neighbors: []) }

        // 邻居想法的认可标签（manual/inline/confirmedAI）→ 去重叶子词 ≤8
        let repository = ThoughtRepository()
        let recognizedSources = [
            ThoughtTagAssignment.Source.manual.rawValue,
            ThoughtTagAssignment.Source.inline.rawValue,
            ThoughtTagAssignment.Source.confirmedAI.rawValue
        ]
        var seen = Set<String>()
        var tags: [String] = []
        for neighbor in neighbors {
            guard let neighborThought = try? repository.fetchByIdInternal(neighbor.thoughtId),
                  let assignments = neighborThought.tagAssignments as? Set<ThoughtTagAssignment> else { continue }
            for assignment in assignments
            where recognizedSources.contains(assignment.source) {
                guard let name = assignment.tag?.name else { continue }
                let leaf = ThoughtTagNormalizer.displayName(name)
                let key = ThoughtTagNormalizer.key(leaf)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if tags.count < maxNeighborTags {
                    tags.append(leaf)
                }
            }
        }
        return SemanticCandidates(neighborTags: tags, neighbors: neighbors)
    }

    /// 当前想法向量：缓存命中直接用；未缓存时按需生成（分类链路内一次网络往返）
    private static func currentVector(thoughtId: UUID, content: String) async -> [Double]? {
        let normalized = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !normalized.isEmpty else { return nil }
        let hash = ThoughtEmbeddingStore.contentHash(of: normalized)

        if let entry = await ThoughtEmbeddingStore.shared.entry(for: thoughtId),
           entry.contentHash == hash, entry.modelVersion == ThoughtEmbeddingStore.modelVersion {
            return entry.vector
        }
        do {
            let provider = HoloBackendAIProvider()
            let vectors = try await provider.embed(texts: [normalized])
            guard let vector = vectors.first, !vector.isEmpty else { return nil }
            await ThoughtEmbeddingStore.shared.upsert(ThoughtEmbeddingEntry(
                thoughtId: thoughtId,
                contentHash: hash,
                modelVersion: ThoughtEmbeddingStore.modelVersion,
                vector: vector,
                updatedAt: Date()
            ))
            return vector
        } catch {
            logger.info("语义候选向量不可用：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 存量回填（设置页 Debug 区手动触发）

    /// 批量回填已整理想法的向量；每批 ≤16 条（单请求上限），批间节流
    static func backfill(limit: Int = 64) async -> Int {
        guard ThoughtSemanticCandidateMode.current != .off else { return 0 }
        let repository = ThoughtRepository()
        guard let organized = try? repository.fetchAll() else { return 0 }

        var embedded = 0
        var batchTexts: [(id: UUID, text: String, hash: String)] = []
        for thought in organized {
            guard embedded + batchTexts.count < limit else { break }
            guard !thought.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let normalized = String(thought.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            guard !normalized.isEmpty else { continue }
            let hash = ThoughtEmbeddingStore.contentHash(of: normalized)
            guard await ThoughtEmbeddingStore.shared.needsEmbedding(thoughtId: thought.id, contentHash: hash) else { continue }
            batchTexts.append((thought.id, normalized, hash))

            if batchTexts.count == 16 {
                embedded += await embedBatch(batchTexts)
                batchTexts.removeAll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 批间 3s 节流
            }
        }
        if !batchTexts.isEmpty {
            embedded += await embedBatch(batchTexts)
        }
        logger.info("语义向量回填完成：\(embedded) 条")
        return embedded
    }

    private static func embedBatch(_ batch: [(id: UUID, text: String, hash: String)]) async -> Int {
        do {
            let provider = HoloBackendAIProvider()
            let vectors = try await provider.embed(texts: batch.map(\.text))
            guard vectors.count == batch.count else { return 0 }
            for (index, item) in batch.enumerated() {
                await ThoughtEmbeddingStore.shared.upsert(ThoughtEmbeddingEntry(
                    thoughtId: item.id,
                    contentHash: item.hash,
                    modelVersion: ThoughtEmbeddingStore.modelVersion,
                    vector: vectors[index],
                    updatedAt: Date()
                ))
            }
            return batch.count
        } catch {
            logger.info("回填批次失败（跳过）：\(error.localizedDescription)")
            return 0
        }
    }
}
