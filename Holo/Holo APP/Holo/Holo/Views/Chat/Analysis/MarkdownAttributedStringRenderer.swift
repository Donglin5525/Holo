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

    /// 异步解析 Markdown 文本为 AttributedString
    static func parse(_ text: String) async -> AttributedString? {
        await Task.detached(priority: .utility) {
            try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }.value
    }

    /// 同步解析（短文本可用，不在热路径上使用）
    static func parseSync(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
