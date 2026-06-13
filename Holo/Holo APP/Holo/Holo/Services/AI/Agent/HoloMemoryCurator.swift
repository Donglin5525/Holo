//
//  HoloMemoryCurator.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.3 Memory Curator
//  把校验后的 claim 路由到记忆目的地。第一阶段只输出 HoloCuratedAgentMemory，不直接写入 store，避免污染现有系统。
//

import Foundation

/// Agent 记忆路由目的地。
enum HoloAgentMemoryRoute: String, Codable, Sendable {
    case responseOnly
    case evidenceOnly
    case episodicMemory
    case longTermCandidate
    case displayOnly
    case suppressionRule
}

/// Curator 输出：一个 claim 的记忆路由决策。
struct HoloCuratedAgentMemory: Codable, Equatable, Sendable {
    var claimID: String
    var route: HoloAgentMemoryRoute
    var title: String
    var summary: String
    var evidenceIDs: [String]
    var expiresInDays: Int?
}

struct HoloMemoryCurator {

    /// 把 claims 路由到记忆目的地。
    /// - Parameters:
    ///   - suppressionKeywords: 用户已拒绝的关键词，命中的 claim 不生成记忆候选。
    func curate(claims: [HoloAgentClaim], patterns: [HoloPatternSignal],
                suppressionKeywords: [String] = []) -> [HoloCuratedAgentMemory] {
        let hasGoalConflict = patterns.contains { $0.type == .goalConflict }
        let hasHighSeverity = patterns.contains { $0.severity == .high || $0.severity == .critical }

        var result: [HoloCuratedAgentMemory] = []
        for claim in claims {
            // suppression 命中 → 跳过，不生成记忆候选
            if Self.matchesSuppression(claim.displayText, keywords: suppressionKeywords) { continue }

            let route = Self.route(hasGoalConflict: hasGoalConflict, hasHighSeverity: hasHighSeverity)
            result.append(HoloCuratedAgentMemory(
                claimID: claim.id,
                route: route,
                title: String(claim.displayText.prefix(20)),
                summary: claim.displayText,
                evidenceIDs: claim.evidenceIDs,
                expiresInDays: route == .episodicMemory ? 30 : nil
            ))
        }
        return result
    }

    private static func route(hasGoalConflict: Bool, hasHighSeverity: Bool) -> HoloAgentMemoryRoute {
        // 目标冲突或高严重度信号 → 情景记忆候选（短期，可演化）
        if hasGoalConflict || hasHighSeverity {
            return .episodicMemory
        }
        // 其余（低价值统计、普通观察）→ 仅响应当轮使用，不进记忆系统
        return .responseOnly
    }

    private static func matchesSuppression(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
