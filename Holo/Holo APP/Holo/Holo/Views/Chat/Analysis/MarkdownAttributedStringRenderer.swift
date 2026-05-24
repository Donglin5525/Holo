//
//  MarkdownAttributedStringRenderer.swift
//  Holo
//
//  Markdown → AttributedString 解析工具
//  从 StreamingTextView 提取，供 Sheet 等场景共享
//

import Foundation

enum MarkdownAttributedStringRenderer {

    /// 判断文本是否值得尝试 Markdown 渲染
    static func shouldRender(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 2_000 else { return false }
        let indicators = ["**", "`", "#", "- ", "* ", "[", "> "]
        return indicators.contains { text.contains($0) }
    }

    /// 将 AI 回复里常见的块级 Markdown 转成 App 端更自然的文本。
    static func normalizeConsumerText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .compactMap(normalizeConsumerLine)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 异步解析 Markdown 文本为 AttributedString
    static func parse(_ text: String) async -> AttributedString? {
        await Task.detached(priority: .utility) {
            let normalized = normalizeConsumerText(text)
            return try? AttributedString(
                markdown: normalized,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }.value
    }

    /// 同步解析（短文本可用，不在热路径上使用）
    static func parseSync(_ text: String) -> AttributedString? {
        let normalized = normalizeConsumerText(text)
        return try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    private static func normalizeConsumerLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("{{card:"), trimmed.hasSuffix("}}") {
            return nil
        }

        if let heading = headingText(from: trimmed) {
            return heading
        }

        if let bullet = unorderedBulletText(from: trimmed) {
            return "• \(bullet)"
        }

        if let numbered = numberedBulletText(from: trimmed) {
            return "• \(numbered)"
        }

        if trimmed.hasPrefix("> ") {
            return String(trimmed.dropFirst(2))
        }

        return line
    }

    private static func headingText(from line: String) -> String? {
        var hashCount = 0
        for character in line {
            guard character == "#" else { break }
            hashCount += 1
        }

        guard (1...6).contains(hashCount) else { return nil }
        let rest = line.dropFirst(hashCount)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func unorderedBulletText(from line: String) -> String? {
        guard line.count > 2 else { return nil }
        let marker = line.first
        guard marker == "*" || marker == "-" || marker == "+" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func numberedBulletText(from line: String) -> String? {
        var digits = ""
        var index = line.startIndex

        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }

        guard !digits.isEmpty,
              index < line.endIndex,
              line[index] == "." else {
            return nil
        }

        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else {
            return nil
        }

        return line[line.index(after: afterDot)...].trimmingCharacters(in: .whitespaces)
    }
}
