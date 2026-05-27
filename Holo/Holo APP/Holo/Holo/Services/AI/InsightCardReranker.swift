//
//  InsightCardReranker.swift
//  Holo
//
//  洞察卡片本地校准层
//  根据偏好画像对卡片排序/降权，不改写 AI 原文
//

import Foundation

struct InsightCardReranker {

    /// 对卡片列表做 rerank，返回排序后的新列表
    /// - Parameters:
    ///   - cards: 原始卡片
    ///   - profile: 用户偏好画像
    /// - Returns: 排序后的卡片（原始数据不变）
    static func rerank(_ cards: [MemoryInsightCard], with profile: InsightPreferenceProfile) -> [MemoryInsightCard] {
        guard !profile.moduleWeights.isEmpty || !profile.dislikedPatterns.isEmpty else {
            return cards
        }

        return cards.sorted { cardA, cardB in
            let scoreA = score(for: cardA, profile: profile)
            let scoreB = score(for: cardB, profile: profile)
            return scoreA > scoreB
        }
    }

    // MARK: - Scoring

    private static func score(for card: MemoryInsightCard, profile: InsightPreferenceProfile) -> Double {
        var score = 1.0

        // 模块权重
        let moduleKey = deriveModuleKey(from: card)
        if let moduleKey = moduleKey,
           let pref = profile.moduleWeights.first(where: { $0.module == moduleKey }) {
            score *= pref.weight
        }

        // 模式惩罚
        if let patternType = card.patternType ?? card.moduleHint,
           let patternPref = profile.dislikedPatterns.first(where: { $0.patternType == patternType }) {
            score *= (1.0 - patternPref.penalty)
        }

        // Critical anomaly 保底：不降权到零
        if card.type == .anomaly, card.anomalySeverity == .critical {
            score = max(score, 0.5)
        }

        return score
    }

    /// 从卡片推导 InsightModuleKey
    private static func deriveModuleKey(from card: MemoryInsightCard) -> InsightModuleKey? {
        switch card.type {
        case .habit: return .habit
        case .finance: return .finance
        case .task: return .task
        case .thought: return .thought
        case .milestone: return .milestone
        case .crossDomain: return .crossDomain
        case .overview: return card.moduleHint.flatMap { InsightModuleKey(rawValue: $0) }
        case .anomaly: return card.moduleHint.flatMap { InsightModuleKey(rawValue: $0) }
        }
    }
}
