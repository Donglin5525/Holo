//
//  MarkdownRenderer.swift
//  Holo
//
//  观点模块 - Markdown 渲染器
//  将 AST 节点树转换为 SwiftUI 视图
//

import SwiftUI

// MARK: - MarkdownRenderer

/// Markdown AST → SwiftUI View 转换器
struct MarkdownRenderer {

    // MARK: - 公共接口

    /// 渲染完整 Markdown 内容为 SwiftUI 视图
    static func render(_ markdown: String) -> some View {
        let document = MarkdownParser.parse(markdown)
        return renderDocument(document)
    }

    /// 渲染纯文本预览（去除格式，截取前 N 字符）
    static func previewText(_ markdown: String, maxLength: Int = 80) -> String {
        let stripped = MarkdownParser.stripFormatting(markdown)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(stripped.prefix(maxLength))
    }

    /// 提取内容中的 # 标签名称
    static func extractTags(_ markdown: String) -> [String] {
        MarkdownParser.extractTags(from: markdown)
    }

    // MARK: - 文档渲染

    /// 渲染文档根节点
    private static func renderDocument(_ document: DocumentNode) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { index, node in
                renderNode(node)
            }
            }
        )
    }

    // MARK: - 节点渲染

    /// 渲染单个 AST 节点
    private static func renderNode(_ node: MarkdownNode) -> AnyView {
        switch node {
        case let textNode as TextNode:
            AnyView(
                Text(textNode.text)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            )

        case let paragraph as ParagraphNode:
            AnyView(
                renderInlineNodes(paragraph.children)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            )

        case let bold as BoldNode:
            AnyView(
                renderInlineNodes(bold.children)
                    .fontWeight(.bold)
            )

        case let italic as ItalicNode:
            AnyView(
                renderInlineNodes(italic.children)
                    .italic()
            )

        case let underline as UnderlineNode:
            AnyView(
                renderInlineNodes(underline.children)
                    .underline()
            )

        case let colored as ColoredNode:
            AnyView(
                renderInlineNodes(colored.children)
                    .foregroundColor(Color(hex: colored.colorHex))
            )

        case let tag as InlineTagNode:
            AnyView(InlineTagChip(tagName: tag.tagName))

        case let item as UnorderedListItemNode:
            AnyView(
                HStack(alignment: .top, spacing: HoloSpacing.xs) {
                    Text("\u{2022}")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 16)
                    renderInlineNodes(item.children)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                }
            )

        case let item as OrderedListItemNode:
            AnyView(
                HStack(alignment: .top, spacing: HoloSpacing.xs) {
                    Text("\(item.index).")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 20, alignment: .trailing)
                    renderInlineNodes(item.children)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                }
            )

        default:
            AnyView(EmptyView())
        }
    }

    // MARK: - 内联节点拼接渲染

    /// 将多个内联节点拼接为单个 Text（利用 SwiftUI Text 拼接特性实现高效渲染）
    private static func renderInlineNodes(_ nodes: [MarkdownNode]) -> AnyView {
        if let combinedText = buildCombinedText(nodes) {
            return AnyView(combinedText)
        } else {
            // 降级：逐个渲染（当包含非 Text 节点时）
            return AnyView(
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                    renderNode(node)
                }
            )
        }
    }

    /// 尝试将内联节点构建为单个拼接的 Text
    private static func buildCombinedText(_ nodes: [MarkdownNode]) -> Text? {
        var result: Text?
        var hasNonText = false

        for node in nodes {
            switch node {
            case let textNode as TextNode:
                let segment = Text(textNode.text)
                result = result.map { $0 + segment } ?? segment

            case let bold as BoldNode:
                guard let inner = buildCombinedText(bold.children) else {
                    hasNonText = true
                    continue
                }
                let segment = inner.bold()
                result = result.map { $0 + segment } ?? segment

            case let italic as ItalicNode:
                guard let inner = buildCombinedText(italic.children) else {
                    hasNonText = true
                    continue
                }
                let segment = inner.italic()
                result = result.map { $0 + segment } ?? segment

            case let underline as UnderlineNode:
                guard let inner = buildCombinedText(underline.children) else {
                    hasNonText = true
                    continue
                }
                let segment = inner.underline()
                result = result.map { $0 + segment } ?? segment

            case let colored as ColoredNode:
                guard let inner = buildCombinedText(colored.children) else {
                    hasNonText = true
                    continue
                }
                let segment = inner.foregroundColor(Color(hex: colored.colorHex))
                result = result.map { $0 + segment } ?? segment

            case let tag as InlineTagNode:
                let segment = Text("#\(tag.tagName)")
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                result = result.map { $0 + segment } ?? segment

            default:
                hasNonText = true
            }
        }

        return hasNonText ? nil : result
    }
}

// MARK: - InlineTagChip

/// 内联标签的独立视图组件（当无法用 Text 拼接时使用）
private struct InlineTagChip: View {
    let tagName: String

    var body: some View {
        Text("#\(tagName)")
            .font(.holoLabel)
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.holoPrimary.opacity(0.1))
            .cornerRadius(HoloRadius.sm)
    }
}
