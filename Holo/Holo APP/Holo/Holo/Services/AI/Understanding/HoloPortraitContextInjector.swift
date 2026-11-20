//
//  HoloPortraitContextInjector.swift
//  Holo
//
//  Phase 4：动态用户画像与跨模块洞察 → AI 对话场景化注入器（纯 Swift，零 App 依赖）。
//
//  原则：
//  1. 宁少勿滥：按当前 userText 相关性与维度权重最多选取 8 条，控制上下文体积。
//  2. 严格区分 [已确认] 与 [推测]：已确认可直接作为事实使用；推测项要求 AI 仅在话题相关时
//     以温和、带条件、不武断的方式自然提及，禁止在无关话题里强行炫耀画像。
//

import Foundation

nonisolated enum HoloPortraitContextInjector {

    /// 为聊天场景渲染动态画像与跨模块洞察块；无活跃条目时返回 nil（零上下文噪音）。
    static func renderForChat(
        store: PortraitStore,
        userText: String?,
        maxItems: Int = 8
    ) -> String? {
        let active = store.entries.values.filter {
            $0.confidence == .confirmed || $0.confidence == .inferred
        }
        guard !active.isEmpty, maxItems > 0 else { return nil }

        let query = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scored: [(entry: PortraitEntry, score: Int)] = active.map { entry in
            (entry, relevanceScore(for: entry, query: query))
        }
        let picked = scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.updatedAt > rhs.entry.updatedAt
            }
            .prefix(maxItems)
            .map(\.entry)

        guard !picked.isEmpty else { return nil }

        var lines: [String] = [
            "--- Holo 用户画像与跨模块洞察（按需参考） ---"
        ]
        for entry in picked {
            let badge = entry.confidence == .confirmed ? "已确认" : "推测"
            let hintSuffix = entry.usageHint.isEmpty ? "" : "（适用：\(entry.usageHint)）"
            lines.append("- [\(entry.dimension.displayTitle)·\(badge)] \(entry.statement)\(hintSuffix)")
        }
        lines.append("使用规则：[已确认] 可直接作为背景事实；[推测] 仅在与当前话题明确相关时以温和、不武断的语气提及（例如「如果有养猫的话…」），话题无关时不要提及；用户若当场纠正则以用户最新说法为准。")
        return lines.joined(separator: "\n")
    }

    private static func relevanceScore(for entry: PortraitEntry, query: String) -> Int {
        var score = 0
        // 基础权重：已确认高于推测；身份/偏好/跨模块洞察优先。
        score += (entry.confidence == .confirmed) ? 30 : 15
        switch entry.dimension {
        case .identity: score += 20
        case .preference: score += 18
        case .crossDomainInsight: score += 16
        case .recentState: score += 12
        case .longTermPattern: score += 10
        }

        // 话题相关性加分：提取 query 中 ≥2 字的中文/英文片段命中 statement / usageHint / evidenceSummary。
        guard !query.isEmpty else { return score }
        let searchable = "\(entry.statement) \(entry.usageHint) \(entry.evidenceSummary)"
        let hits = keywordHits(query: query, target: searchable)
        score += hits * 40
        return score
    }

    private static func keywordHits(query: String, target: String) -> Int {
        let chars = Array(query)
        guard chars.count >= 2 else { return target.contains(query) ? 1 : 0 }
        var seen = Set<String>()
        var hits = 0
        for i in 0..<(chars.count - 1) {
            let bigram = String(chars[i...(i + 1)])
            let trimmed = bigram.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 2, seen.insert(trimmed).inserted else { continue }
            if target.contains(trimmed) {
                hits += 1
            }
        }
        return min(hits, 4)
    }
}
