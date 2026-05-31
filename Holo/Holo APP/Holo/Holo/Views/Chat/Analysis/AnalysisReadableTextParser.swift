//
//  AnalysisReadableTextParser.swift
//  Holo
//
//  Turns dense AI analysis prose into scannable reading sections.
//

import Foundation

nonisolated struct AnalysisReadableModel: Equatable {
    let headline: String
    let facts: [AnalysisReadableFact]
    let remainingText: String
}

nonisolated struct AnalysisReadableFact: Equatable, Identifiable {
    let id: Int
    let kicker: String
    let body: String
}

nonisolated enum AnalysisReadableTextParser {

    static func parse(text: String, fallbackHeadline: String) -> AnalysisReadableModel {
        let sentences = normalizedSentences(from: text)
        let facts = buildFacts(from: sentences)
        let remaining = sentences
            .filter { sentence in
                !facts.contains { fact in fact.body.contains(sentence) }
            }
            .joined(separator: "\n\n")

        return AnalysisReadableModel(
            headline: fallbackHeadline,
            facts: facts,
            remainingText: remaining
        )
    }

    private static func normalizedSentences(from text: String) -> [String] {
        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map { cleanLine($0) }
            .filter { !$0.isEmpty && !isCardMarker($0) && !isSectionHeading($0) }

        return cleanedLines
            .flatMap { line in
                splitSentences(line)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func cleanLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\*\*(.+)\*\*$"#, with: "$1", options: .regularExpression)
    }

    private static func isCardMarker(_ text: String) -> Bool {
        text.hasPrefix("{{card:") && text.hasSuffix("}}")
    }

    private static func isSectionHeading(_ text: String) -> Bool {
        ["事实", "结论", "核心结论", "指标", "排行", "建议"].contains(text)
    }

    private static func splitSentences(_ text: String) -> [String] {
        let pattern = #"[^。！？!?]+[。！？!?]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func buildFacts(from sentences: [String]) -> [AnalysisReadableFact] {
        var facts: [AnalysisReadableFact] = []
        var used = Set<Int>()

        appendFact(
            kicker: "支出节奏",
            from: sentences,
            used: &used,
            into: &facts,
            keywords: ["总支出", "日均"]
        )
        appendCombinedFact(
            kicker: "固定成本",
            from: sentences,
            used: &used,
            into: &facts,
            primaryKeywords: ["收入", "固定", "房租", "必要"],
            maxSentenceCount: 2
        )
        appendFact(
            kicker: "可调整空间",
            from: sentences,
            used: &used,
            into: &facts,
            keywords: ["可调整", "主要集中", "支出前三", "购物", "餐饮"]
        )

        for (index, sentence) in sentences.enumerated() where facts.count < 3 && !used.contains(index) {
            facts.append(AnalysisReadableFact(
                id: facts.count,
                kicker: fallbackKicker(for: facts.count),
                body: sentence
            ))
            used.insert(index)
        }

        return facts
    }

    private static func appendFact(
        kicker: String,
        from sentences: [String],
        used: inout Set<Int>,
        into facts: inout [AnalysisReadableFact],
        keywords: [String]
    ) {
        guard let match = sentences.enumerated().first(where: { index, sentence in
            !used.contains(index) && containsAny(sentence, keywords: keywords)
        }) else {
            return
        }
        facts.append(AnalysisReadableFact(id: facts.count, kicker: kicker, body: match.element))
        used.insert(match.offset)
    }

    private static func appendCombinedFact(
        kicker: String,
        from sentences: [String],
        used: inout Set<Int>,
        into facts: inout [AnalysisReadableFact],
        primaryKeywords: [String],
        maxSentenceCount: Int
    ) {
        let matches = sentences.enumerated()
            .filter { index, sentence in
                !used.contains(index) && containsAny(sentence, keywords: primaryKeywords)
            }
            .prefix(maxSentenceCount)

        guard !matches.isEmpty else { return }
        let body = matches.map(\.element).joined(separator: " ")
        facts.append(AnalysisReadableFact(id: facts.count, kicker: kicker, body: body))
        matches.forEach { used.insert($0.offset) }
    }

    private static func fallbackKicker(for index: Int) -> String {
        switch index {
        case 0: return "核心事实"
        case 1: return "结构变化"
        case 2: return "下一步"
        default: return "补充"
        }
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
