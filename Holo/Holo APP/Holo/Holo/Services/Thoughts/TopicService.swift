//
//  TopicService.swift
//  Holo
//
//  观点主题业务服务（P1.5.1）
//  主主题展示层取 + 收纳判断（Thought+Tag+Topic 三者交集）
//  纯基于 Core Data 关系，无状态
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import Foundation
import CoreData

struct TopicService {

    /// 取一条观点的主展示主题：thoughts.count 最高的可见 Topic；无则 nil（spec 决策 11）
    /// - Note: 不用 updatedAt（iCloud 跨设备时钟不可靠）、不用缓存 thoughtCount
    func primaryDisplayTopic(for thought: Thought) -> Topic? {
        guard let topics = thought.topics as? Set<Topic> else { return nil }
        return topics
            .filter(\.isVisibleTopic)
            .max { topicThoughtCount($0) < topicThoughtCount($1) }
    }

    /// 判断 assignment 是否已被主题收纳（三者交集，spec §6.3 展示规则 / 决策 15）
    /// `assignment.thought ∈ activeTopic.thoughts`
    /// AND `assignment.tag ∈ activeTopic.associatedTags`
    /// AND `assignment.source ∈ [.ai, .confirmedAI]`
    /// AND `assignment.rejectedAt == nil`
    func isAbsorbed(_ assignment: ThoughtTagAssignment) -> Bool {
        guard let thought = assignment.thought,
              let tag = assignment.tag else { return false }
        let source = ThoughtTagAssignment.Source(rawValue: assignment.source)
        guard source == .ai || source == .confirmedAI else { return false }
        guard assignment.rejectedAt == nil else { return false }

        guard let topics = thought.topics as? Set<Topic> else { return false }
        for topic in topics where topic.isVisibleTopic {
            let topicThoughts = topic.thoughts as? Set<Thought> ?? []
            let topicTags = topic.associatedTags as? Set<ThoughtTag> ?? []
            if topicThoughts.contains(thought) && topicTags.contains(tag) {
                return true
            }
        }
        return false
    }

    /// Topic 的观点数（实时算）
    private func topicThoughtCount(_ topic: Topic) -> Int {
        (topic.thoughts as? Set<Thought>)?.count ?? 0
    }
}
