//
//  SemanticEvaluationExporter.swift
//  Holo
//
//  P2（方案 §5.4 Gate）：语义候选评估样本导出。
//  从最近已整理想法分层抽 40 条，导出每条的基线候选池（existingTags+recentAITags）
//  与增强候选池（+语义近邻标签），供东林人工标注「可接受标签 Top-3」后
//  对比覆盖率（Gate：提升 ≥10pp 才开 inject）。
//

import Foundation

@MainActor
enum SemanticEvaluationExporter {

    static let sampleCount = 40

    struct Sample: Codable {
        let thoughtId: UUID
        let contentPreview: String
        let activeTopic: String?
        let currentTags: [String]
        let baselineCandidates: [String]
        let semanticNeighborTags: [String]
        let neighborCosines: [Double]
    }

    /// 生成分层样本并写入临时 JSON 文件；无已整理想法或写入失败返回 nil
    static func export() async -> URL? {
        let repository = ThoughtRepository()
        guard let organized = try? repository.fetchAll(), !organized.isEmpty else { return nil }

        // 分层抽样：按时间均匀取样本（不偏袒近期）
        let pool = organized.sorted { $0.createdAt < $1.createdAt }
        var picked: [Thought] = []
        if pool.count <= sampleCount {
            picked = pool
        } else {
            let stride = Double(pool.count) / Double(sampleCount)
            for index in 0..<sampleCount {
                picked.append(pool[Int(Double(index) * stride)])
            }
        }

        let existingTags = repository.fetchUserRecognizedTagNames(limit: 60)
        let recentAITags = (try? repository.fetchRecentAITagLeafNames()) ?? []
        let baseline = Array(Set(existingTags + recentAITags).sorted())

        let recognizedSources = [
            ThoughtTagAssignment.Source.manual.rawValue,
            ThoughtTagAssignment.Source.inline.rawValue,
            ThoughtTagAssignment.Source.confirmedAI.rawValue
        ]

        var samples: [Sample] = []
        for thought in picked {
            var neighborTags: [String] = []
            var cosines: [Double] = []
            // 直接读缓存向量计算近邻（不发起网络请求；未回填的想法该项为空）
            if let entry = await ThoughtEmbeddingStore.shared.entry(for: thought.id) {
                let neighbors = await ThoughtEmbeddingStore.shared.topNeighbors(
                    of: entry.vector,
                    excluding: thought.id,
                    limit: ThoughtSemanticCandidateEngine.neighborLimit
                )
                var seen = Set<String>()
                for neighbor in neighbors {
                    guard let neighborThought = try? repository.fetchByIdInternal(neighbor.thoughtId),
                          let assignments = neighborThought.tagAssignments as? Set<ThoughtTagAssignment> else { continue }
                    for assignment in assignments
                    where recognizedSources.contains(assignment.source) {
                        guard let name = assignment.tag?.name else { continue }
                        let leaf = ThoughtTagNormalizer.displayName(name)
                        let key = ThoughtTagNormalizer.key(leaf)
                        guard !key.isEmpty, seen.insert(key).inserted else { continue }
                        if neighborTags.count < ThoughtSemanticCandidateEngine.maxNeighborTags {
                            neighborTags.append(leaf)
                            cosines.append(neighbor.cosine)
                        }
                    }
                }
            }

            samples.append(Sample(
                thoughtId: thought.id,
                contentPreview: String(thought.content.prefix(120)),
                activeTopic: thought.primaryTopicTitleForEvaluation,
                currentTags: thought.tagArray.map { ThoughtTagNormalizer.lastSegment($0.name) },
                baselineCandidates: baseline,
                semanticNeighborTags: neighborTags,
                neighborCosines: cosines
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(samples) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-evaluation-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

extension Thought {
    /// 评估导出用：首个分类主题标题（只读）
    var primaryTopicTitleForEvaluation: String? {
        (topics as? Set<Topic>)?
            .first(where: { $0.isClassificationTopic })?
            .title
    }
}
