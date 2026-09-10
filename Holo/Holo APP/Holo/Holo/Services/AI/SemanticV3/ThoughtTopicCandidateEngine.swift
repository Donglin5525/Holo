//
//  ThoughtTopicCandidateEngine.swift
//  Holo
//
//  候选召回引擎（语义图谱 V3 Phase 3，方案 §9.2 步骤 5 / §11.1）
//
//  两层召回：Topic centroid Top3 + 全局近邻 Top20 投票；合并去重后 ≤3 个候选。
//  向量只召回候选，永不直接决定用户可见关系（核心不变量 2）。
//  排除：已拒绝 pair（rejected 墓碑）、merged/hidden 主题、删除想法。
//

import CoreData
import Foundation

struct ThoughtTopicCandidate: Equatable {
    var topicID: UUID
    var topicTitle: String
    /// centroid 相似度（centroid 命中时有效）
    var centroidCosine: Float?
    /// 近邻投票数与平均相似度
    var neighborVotes: Int
    var neighborMeanCosine: Float
    /// 综合分数（排序用；决策层另行计算不依赖单一分数）
    var recallScore: Float {
        max(centroidCosine ?? 0, neighborVotes > 0 ? neighborMeanCosine : 0)
    }
}

struct ThoughtTopicCandidateOutcome: Equatable {
    var candidates: [ThoughtTopicCandidate]
    /// 目标想法自己的近邻（供决策层计算 margin/歧义）
    var neighborThoughtIDs: [UUID]
    /// 召回阶段即放弃的原因（无向量/无有效主题/全部低于阈值）
    var reason: String?
}

enum ThoughtTopicCandidateEngine {

    /// 顶层入口：目标向量 → 候选主题列表。
    /// - Parameters:
    ///   - targetVector: 目标想法向量（已归一化）
    ///   - context: Core Data 读上下文（Topic/link 读取）
    static func recall(targetVector: [Float],
                       thoughtID: UUID,
                       store: ThoughtSemanticStore,
                       index: (any LocalSemanticIndex)?,
                       context: NSManagedObjectContext,
                       calibration: ThoughtSemanticCalibration) async -> ThoughtTopicCandidateOutcome {

        // 1. 有效主题集合（可见状态；排除 merged/hidden——§9.2 步骤 5）
        let activeTopics: [(id: UUID, title: String)] = await context.perform {
            let request = Topic.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil")
            let topics = (try? context.fetch(request)) ?? []
            return topics
                .filter { $0.isVisibleTopic }
                .map { ($0.id, $0.title) }
        }

        // 2. 为每个主题动态计算 centroid（成员=有效 active link 的想法向量；shadow 阶段不落表）
        var centroidScores: [(UUID, String, Float)] = []
        for topic in activeTopics {
            guard let centroid = await centroidVector(topicID: topic.id, context: context, store: store) else { continue }
            let cosine = SemanticVectorMath.cosineSimilarity(targetVector, centroid)
            if cosine >= calibration.recallMinCosine {
                centroidScores.append((topic.id, topic.title, cosine))
            }
        }
        centroidScores.sort { $0.2 > $1.2 }
        let centroidTop = centroidScores.prefix(3)

        // 3. 全局近邻 Top20 投票
        var neighborIDs: [UUID] = []
        var voteScores: [UUID: (votes: Int, cosineSum: Float, title: String)] = [:]
        if let index {
            let excluded = await rejectedPairTopicIDs(thoughtID: thoughtID, context: context)
            if let neighbors = try? await index.search(vector: targetVector, topK: 20,
                                                       filter: SemanticIndexFilter(excludedIDs: excluded.union([thoughtID]))),
               !neighbors.isEmpty {
                neighborIDs = neighbors.map(\.thoughtID)
                // 近邻的想法 → 其主题（投影有效集合）
                let topicsByThought = await topicsForThoughts(ids: neighborIDs, context: context)
                for neighbor in neighbors {
                    guard let topics = topicsByThought[neighbor.thoughtID] else { continue }
                    for topic in topics where !excluded.contains(topic.id) {
                        var entry = voteScores[topic.id] ?? (0, 0, topic.title)
                        entry.votes += 1
                        entry.cosineSum += neighbor.similarity
                        entry.title = topic.title
                        voteScores[topic.id] = entry
                    }
                }
            }
        }

        // 4. 合并：centroid 命中 + 票数达标者，按综合分排序取 ≤3
        var merged: [UUID: ThoughtTopicCandidate] = [:]
        for (id, title, cosine) in centroidTop {
            merged[id] = ThoughtTopicCandidate(topicID: id, topicTitle: title, centroidCosine: cosine,
                                               neighborVotes: 0, neighborMeanCosine: 0)
        }
        for (id, entry) in voteScores where entry.votes >= calibration.neighborVoteMinCount {
            let mean = entry.cosineSum / Float(entry.votes)
            if var existing = merged[id] {
                existing.neighborVotes = entry.votes
                existing.neighborMeanCosine = mean
                merged[id] = existing
            } else if merged.count < 3 {
                merged[id] = ThoughtTopicCandidate(topicID: id, topicTitle: entry.title, centroidCosine: nil,
                                                   neighborVotes: entry.votes, neighborMeanCosine: mean)
            }
        }

        let candidates = merged.values.sorted { $0.recallScore > $1.recallScore }.prefix(3).map { $0 }
        let reason: String?
        if candidates.isEmpty {
            reason = activeTopics.isEmpty ? "no_visible_topics" : "below_recall_threshold"
        } else {
            reason = nil
        }
        return ThoughtTopicCandidateOutcome(candidates: Array(candidates),
                                            neighborThoughtIDs: neighborIDs,
                                            reason: reason)
    }

    /// 主题 centroid：成员（active link）向量平均后归一化；无成员向量返回 nil。
    static func centroidVector(topicID: UUID,
                               context: NSManagedObjectContext,
                               store: ThoughtSemanticStore) async -> [Float]? {
        let memberIDs: [UUID] = await context.perform {
            let request = ThoughtTopicLink.fetchRequest()
            request.predicate = NSPredicate(format: "topic.id == %@ AND state == %@", topicID as CVarArg, "active")
            let links = (try? context.fetch(request)) ?? []
            return links.compactMap { $0.thought?.id }
        }
        guard !memberIDs.isEmpty else { return nil }
        var sum: [Float]? = nil
        var count = 0
        for id in memberIDs {
            guard let item = try? await store.item(thoughtID: id),
                  item.state == "active",
                  let vector = try? await store.loadVector(thoughtID: id) else { continue }
            if sum == nil { sum = Array(repeating: Float(0), count: vector.count) }
            guard sum?.count == vector.count else { continue }
            for i in vector.indices { sum![i] += vector[i] }
            count += 1
        }
        guard count > 0, var result = sum else { return nil }
        return SemanticVectorMath.normalized(result)
    }

    /// 该想法已被用户拒绝的 pair 主题集合（墓碑压召回，§9.2 步骤 5 排除项）。
    static func rejectedPairTopicIDs(thoughtID: UUID, context: NSManagedObjectContext) async -> Set<UUID> {
        await context.perform {
            let request = ThoughtTopicLink.fetchRequest()
            request.predicate = NSPredicate(format: "thought.id == %@ AND state == %@", thoughtID as CVarArg, "rejected")
            let links = (try? context.fetch(request)) ?? []
            return Set(links.compactMap { $0.topic?.id })
        }
    }

    /// 批量读取多条想法的有效主题（投影：active 行）。
    static func topicsForThoughts(ids: [UUID], context: NSManagedObjectContext) async -> [UUID: [(id: UUID, title: String)]] {
        await context.perform {
            let request = ThoughtTopicLink.fetchRequest()
            request.predicate = NSPredicate(format: "thought.id IN %@ AND state == %@", ids, "active")
            let links = (try? context.fetch(request)) ?? []
            var out: [UUID: [(UUID, String)]] = [:]
            for link in links {
                guard let thought = link.thought, let topic = link.topic, topic.isVisibleTopic else { continue }
                out[thought.id, default: []].append((topic.id, topic.title))
            }
            return out
        }
    }
}
