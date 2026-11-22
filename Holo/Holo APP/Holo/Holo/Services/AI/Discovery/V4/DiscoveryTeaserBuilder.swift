import Foundation

// 「一个发现」预告问题拼装（2026-11-21 Plus 分层 I3，纯逻辑、可单测）。
//
// 规则真源：docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/01 §5。
// - 原料：本次 packet.features + 本机短句（CandidateBuilder.Output.teaserPhrases）；
// - 不同领域两两配对成「A，同一段时间B。这两件事有关系吗？」，落单的写「A，Holo 想帮你看看是为什么。」；
// - 最多 3 条；排除今天发现卡已经引用的特征；含数字的整条丢弃。
// 这些问题只陈述记录里的事实，不下结论，不调模型。

nonisolated struct DiscoveryTeaserClue: Codable, Equatable, Sendable, Identifiable {
    /// 稳定标识：短句拼接（同一组事实同一个 id，跨天重组包也不变）
    let id: String
    /// 组成本问题的短句（点名时据此反查当前 feature id）
    let phrases: [String]
    /// 对应领域（finance/health/habit…），用于行首图标
    let domains: [String]
    /// 展示文本
    let text: String
}

nonisolated enum DiscoveryTeaserBuilder {
    static let maxClues = 3

    static func build(
        packet: InsightInputPacket,
        phrases: [String: String],
        excludingFeatureIds: Set<String> = []
    ) -> [DiscoveryTeaserClue] {
        var pool: [(phrase: String, domain: String)] = packet.features.compactMap { feature in
            guard !excludingFeatureIds.contains(feature.id), let phrase = phrases[feature.id] else { return nil }
            return (phrase, feature.domain)
        }
        var clues: [DiscoveryTeaserClue] = []
        while !pool.isEmpty && clues.count < maxClues {
            let first = pool.removeFirst()
            let clue: DiscoveryTeaserClue
            if let index = pool.firstIndex(where: { $0.domain != first.domain }) {
                let second = pool.remove(at: index)
                // 模板（2026-11-22 东林拍板精简）：去掉尾部问句，只留两句事实并置。
                clue = DiscoveryTeaserClue(
                    id: "\(first.phrase)|\(second.phrase)",
                    phrases: [first.phrase, second.phrase],
                    domains: [first.domain, second.domain],
                    text: "\(first.phrase)，同一段时间\(dropFirstRecent(second.phrase))。"
                )
            } else {
                clue = DiscoveryTeaserClue(
                    id: first.phrase,
                    phrases: [first.phrase],
                    domains: [first.domain],
                    text: "\(first.phrase)。"
                )
            }
            // 数字纪律只作用于可变部分（短句）：固定句式「这两件事有关系吗？」里的「两」
            // 是文案真源原文、不是数据数字，检查整句会把每一对配对问题都误杀（01 §5 第 2/5 条并行推演定谳）。
            guard !clue.phrases.contains(where: { InsightNumberDiscipline.containsNumerals(in: $0) }) else { continue }
            clues.append(clue)
        }
        return clues
    }

    /// 第二句去掉第一个「最近」，避免「最近…，同一段时间最近…」。
    static func dropFirstRecent(_ phrase: String) -> String {
        guard let range = phrase.range(of: "最近") else { return phrase }
        var result = phrase
        result.removeSubrange(range)
        return result
    }
}
