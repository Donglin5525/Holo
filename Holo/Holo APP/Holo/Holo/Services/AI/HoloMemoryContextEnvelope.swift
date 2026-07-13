//
//  HoloMemoryContextEnvelope.swift
//  Holo
//
//  统一记忆上下文、相关性排序与模型使用标记解析
//

import Foundation

enum HoloMemoryRelevanceRanker {
    static func rank(
        _ memories: [HoloLongTermMemory],
        queryText: String?,
        limit: Int,
        requireQueryMatch: Bool = false,
        now: Date = Date()
    ) -> [HoloLongTermMemory] {
        let candidates = requireQueryMatch
            ? memories.filter { hasQueryMatch($0, queryText: queryText) }
            : memories
        return Array(candidates.sorted { lhs, rhs in
            let leftScore = score(lhs, queryText: queryText, now: now)
            let rightScore = score(rhs, queryText: queryText, now: now)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(limit))
    }

    static func hasQueryMatch(_ memory: HoloLongTermMemory, queryText: String?) -> Bool {
        let haystack = normalized("\(memory.subjectKey) \(memory.title) \(memory.displaySummary) \(memory.aiUseSummary)")
        return queryTokens(queryText).contains { haystack.contains($0) }
    }

    static func isDeterministicMetricQuery(_ queryText: String?) -> Bool {
        guard let queryText else { return false }
        let normalizedText = normalized(queryText)
        let metricTerms = ["多少", "几次", "总计", "合计", "平均", "最高", "最低", "金额", "数量"]
        let interpretiveTerms = ["为什么", "原因", "建议", "怎么", "如何", "复盘", "变化", "趋势", "记得", "记住"]
        return metricTerms.contains { normalizedText.contains($0) }
            && !interpretiveTerms.contains { normalizedText.contains($0) }
    }

    private static func score(
        _ memory: HoloLongTermMemory,
        queryText: String?,
        now: Date
    ) -> Double {
        var value: Double
        switch memory.confidence {
        case .high: value = 3
        case .medium: value = 2
        case .low: value = 1
        }
        value += min(Double(memory.evidence.count), 4) * 0.25
        if memory.sensitivity == .normal { value += 0.5 }

        let ageDays = max(0, now.timeIntervalSince(memory.updatedAt) / 86_400)
        value += max(0, 2 - ageDays / 30)

        let haystack = normalized("\(memory.subjectKey) \(memory.title) \(memory.displaySummary) \(memory.aiUseSummary)")
        let matches = queryTokens(queryText).filter { haystack.contains($0) }.count
        value += Double(matches) * 4
        return value
    }

    private static func queryTokens(_ text: String?) -> Set<String> {
        guard let text else { return [] }
        let segments = normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        var tokens = Set(segments)
        for segment in segments where segment.count >= 4 {
            let characters = Array(segment)
            for index in 0..<(characters.count - 1) {
                tokens.insert(String(characters[index...index + 1]))
            }
        }
        return tokens
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HoloMemoryContextEnvelope {
    static func render(_ summary: HoloMemoryPromptSummary) -> String {
        guard !summary.entries.isEmpty else { return "" }
        var lines = ["--- 可用长期记忆 ---"]
        for entry in summary.entries {
            lines.append("- [memory_id=\(entry.id)] \(entry.title)：\(entry.aiUseSummary)")
            if !entry.prohibitedInferences.isEmpty {
                lines.append("  禁止推断：\(entry.prohibitedInferences.joined(separator: "；"))")
            }
        }
        lines.append("规则：记忆只能辅助理解，不得覆盖当前输入；仅当最终回答确实使用某条记忆时，在回答末尾追加 [[HOLO_MEMORY_IDS:id1,id2]]。未实际使用则不要追加。")
        return lines.joined(separator: "\n")
    }

    static func renderBackground(_ summary: HoloMemoryPromptSummary) -> String {
        guard !summary.entries.isEmpty else { return "" }
        var lines = ["长期记忆背景（只辅助理解本期变化，当前周期数据优先）："]
        for entry in summary.entries {
            lines.append("- [memory_id=\(entry.id)] \(entry.title)：\(entry.aiUseSummary)")
            if !entry.prohibitedInferences.isEmpty {
                lines.append("  禁止推断：\(entry.prohibitedInferences.joined(separator: "；"))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct HoloMemoryUsageMarkerResult: Equatable {
    var cleanText: String
    var usedMemoryIDs: [String]
}

enum HoloMemoryUsageMarker {
    static func visibleTextWhileStreaming(_ text: String) -> String {
        let markerPrefix = "[[HOLO_MEMORY_IDS:"
        if let markerStart = text.range(of: markerPrefix) {
            return String(text[..<markerStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let maximumPartialLength = min(text.count, markerPrefix.count - 1)
        guard maximumPartialLength > 0 else { return text }
        for length in stride(from: maximumPartialLength, through: 2, by: -1) {
            let suffix = String(text.suffix(length))
            if markerPrefix.hasPrefix(suffix) {
                return String(text.dropLast(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func parseAndStrip(
        _ text: String,
        allowedMemoryIDs: Set<String>
    ) -> HoloMemoryUsageMarkerResult {
        let pattern = #"\[\[HOLO_MEMORY_IDS:([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return HoloMemoryUsageMarkerResult(cleanText: text, usedMemoryIDs: [])
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var ids: [String] = []
        for match in matches where match.numberOfRanges > 1 {
            guard let idRange = Range(match.range(at: 1), in: text) else { continue }
            for id in text[idRange].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if allowedMemoryIDs.contains(id), !ids.contains(id) { ids.append(id) }
            }
        }
        var clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        if let incompleteMarker = clean.range(of: "[[HOLO_MEMORY_IDS:") {
            clean.removeSubrange(incompleteMarker.lowerBound..<clean.endIndex)
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return HoloMemoryUsageMarkerResult(cleanText: clean, usedMemoryIDs: ids)
    }
}
