//
//  ConvergenceSuggestion.swift
//  Holo
//
//  跨观点归并建议（P2.2，thought_tag_convergence purpose 的单条输出）
//  AI 识别「多条观点指向同一长期主题」后给出的归并建议：主题名 / 关联观点 / 来源词
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md §6.2
//

import Foundation

/// AI 跨观点归并建议（承载 thought_tag_convergence purpose 的单条输出）
struct ConvergenceSuggestion: Identifiable, Equatable {
    /// 客户端生成 id（Identifiable，UI 列表用；AI 不返回 id）
    let id: UUID
    /// 建议主题名（2-6 字稳定方向词）
    let topicTitle: String
    /// 归入现有主题 id（nil 表示建议新建主题）
    let matchedTopicId: UUID?
    /// 被归并的观点 id 列表
    let thoughtIds: [UUID]
    /// 来源词（被归并观点的代表性 .ai 碎片标签）
    let sourceTerms: [String]
    /// 置信度 0-1
    let confidence: Double
    /// 一句话理由
    let reason: String

    init(
        id: UUID = UUID(),
        topicTitle: String,
        matchedTopicId: UUID?,
        thoughtIds: [UUID],
        sourceTerms: [String],
        confidence: Double,
        reason: String
    ) {
        self.id = id
        self.topicTitle = topicTitle
        self.matchedTopicId = matchedTopicId
        self.thoughtIds = thoughtIds
        self.sourceTerms = sourceTerms
        self.confidence = confidence
        self.reason = reason
    }
}

extension ConvergenceSuggestion {

    /// 从 AI JSON 单条对象构造
    /// - matchedTopicId / thoughtIds 为字符串，需转 UUID（容错：非法 id 丢弃）
    /// - Returns: 缺主题名或无有效关联观点时返回 nil（无意义建议丢弃）
    init?(json: [String: Any]) {
        guard let topicTitle = json["topicTitle"] as? String, !topicTitle.isEmpty else { return nil }

        let matchedId: UUID? = {
            if let s = json["matchedTopicId"] as? String, let uuid = UUID(uuidString: s) {
                return uuid
            }
            return nil
        }()

        let idStrings = json["thoughtIds"] as? [String] ?? []
        let thoughtIds = idStrings.compactMap { UUID(uuidString: $0) }
        guard !thoughtIds.isEmpty else { return nil }  // 无关联观点的建议无意义

        let sourceTerms = (json["sourceTerms"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let confidence = (json["confidence"] as? Double) ?? 0.5
        let reason = (json["reason"] as? String) ?? ""

        self.init(
            topicTitle: topicTitle,
            matchedTopicId: matchedId,
            thoughtIds: thoughtIds,
            sourceTerms: sourceTerms,
            confidence: confidence,
            reason: reason
        )
    }
}
