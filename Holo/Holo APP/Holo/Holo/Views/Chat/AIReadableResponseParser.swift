//
//  AIReadableResponseParser.swift
//  Holo
//
//  将普通 AI 文本解析为与领域无关的阅读块，供聊天页稳定兜底。
//

import Foundation

nonisolated enum AIReadableResponseBlock: Equatable, Sendable {
    case lead(String)
    case paragraph(String)
    case heading(String)
    case unorderedList([String])
    case orderedList([String])
}

nonisolated struct AIReadableResponseDocument: Equatable, Sendable {
    let blocks: [AIReadableResponseBlock]
    let detailBlocks: [AIReadableResponseBlock]

    var hasDetails: Bool {
        !detailBlocks.isEmpty
    }
}

nonisolated enum AIReadableResponseParser {

    static func parse(_ text: String) -> AIReadableResponseDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return AIReadableResponseDocument(blocks: [], detailBlocks: [])
        }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [AIReadableResponseBlock] = []
        var detailBlocks: [AIReadableResponseBlock] = []
        var paragraphLines: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [String] = []
        var isCollectingDetails = false

        func append(_ block: AIReadableResponseBlock) {
            if isCollectingDetails {
                detailBlocks.append(block)
            } else {
                blocks.append(block)
            }
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph))
        }

        func flushUnorderedList() {
            guard !unorderedItems.isEmpty else { return }
            append(.unorderedList(unorderedItems))
            unorderedItems.removeAll(keepingCapacity: true)
        }

        func flushOrderedList() {
            guard !orderedItems.isEmpty else { return }
            append(.orderedList(orderedItems))
            orderedItems.removeAll(keepingCapacity: true)
        }

        func flushAll() {
            flushParagraph()
            flushUnorderedList()
            flushOrderedList()
        }

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if isCardMarker(trimmed) {
                flushAll()
                continue
            }

            let headingText = normalizedHeadingText(from: trimmed)
            if isDetailHeading(headingText) {
                flushAll()
                isCollectingDetails = true
                continue
            }

            if isHeadingLine(
                rawLine: trimmed,
                normalizedText: headingText,
                index: index,
                lines: lines
            ) {
                flushAll()
                append(.heading(headingText))
                continue
            }

            if let item = unorderedListItem(from: trimmed) {
                flushParagraph()
                flushOrderedList()
                unorderedItems.append(item)
                continue
            }

            if let item = orderedListItem(from: trimmed) {
                flushParagraph()
                flushUnorderedList()
                orderedItems.append(item)
                continue
            }

            flushUnorderedList()
            flushOrderedList()
            paragraphLines.append(rawLine.trimmingCharacters(in: .whitespaces))
        }

        flushAll()
        promoteLeadIfNeeded(in: &blocks, hasDetails: !detailBlocks.isEmpty)

        return AIReadableResponseDocument(
            blocks: blocks,
            detailBlocks: detailBlocks
        )
    }

    private static func promoteLeadIfNeeded(
        in blocks: inout [AIReadableResponseBlock],
        hasDetails: Bool
    ) {
        guard let first = blocks.first,
              case .paragraph(let text) = first,
              text.count <= 80,
              blocks.count > 1 || hasDetails else {
            return
        }
        blocks[0] = .lead(text)
    }

    private static func isCardMarker(_ line: String) -> Bool {
        line.hasPrefix("{{card:") && line.hasSuffix("}}")
    }

    private static func normalizedHeadingText(from line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)

        while result.hasPrefix("#") {
            result.removeFirst()
        }
        result = result.trimmingCharacters(in: .whitespaces)

        if result.hasPrefix("**"), result.hasSuffix("**"), result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    private static func isDetailHeading(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            "详细分析",
            "更多分析",
            "完整分析",
            "判断依据",
            "详细依据",
            "补充信息",
            "更多细节"
        ].contains(normalized)
    }

    private static func isHeadingLine(
        rawLine: String,
        normalizedText: String,
        index: Int,
        lines: [String]
    ) -> Bool {
        if rawLine.hasPrefix("#") {
            return !normalizedText.isEmpty
        }

        if rawLine.hasPrefix("**"), rawLine.hasSuffix("**"), normalizedText.count <= 24 {
            return true
        }

        guard index > 0,
              lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              index + 1 < lines.count,
              !lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalizedText.count <= 18,
              !containsSentencePunctuation(normalizedText) else {
            return false
        }

        let exactHeadings: Set<String> = [
            "事实", "变化", "模式", "建议", "结论", "整体状态",
            "下一步", "需要留意", "可以怎么做", "为什么"
        ]
        if exactHeadings.contains(normalizedText) {
            return true
        }

        let headingPrefixes = ["可以先", "先做", "先从", "值得先"]
        let headingSuffixes = ["方面", "建议", "变化", "结论", "状态", "情况"]
        return headingPrefixes.contains { normalizedText.hasPrefix($0) }
            || headingSuffixes.contains { normalizedText.hasSuffix($0) }
    }

    private static func containsSentencePunctuation(_ text: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: "。！？!?，,；;")
        return text.rangeOfCharacter(from: punctuation) != nil
    }

    private static func unorderedListItem(from line: String) -> String? {
        let markers = ["- ", "* ", "+ ", "• ", "· "]
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else {
            return nil
        }
        let item = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func orderedListItem(from line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }

        guard index > line.startIndex,
              index < line.endIndex,
              line[index] == "." || line[index] == "、" else {
            return nil
        }

        index = line.index(after: index)
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        guard index < line.endIndex else { return nil }
        return String(line[index...]).trimmingCharacters(in: .whitespaces)
    }
}
