//
//  AIReadableResponseView.swift
//  Holo
//
//  AI 普通回答的通用阅读视图：文字为底座，结构按需增强。
//

import SwiftUI

// MARK: - 进程级解析缓存
//
// @State 只在单元格存活期间有效：LazyVStack 把滑出屏幕的消息回收后，再次滑入会
// 重新走「纯文本秒开→异步解析→升级结构化」，两种排版高度不同，表现为滚动中的
// 内容跳动；上下反复滑动时每条消息反复重演。进程级缓存让第二次进屏同步命中、
// 首帧即结构化，消除重复解析与高度跳变。聊天消息文本定稿后不可变，按全文做键。

private struct AIResponseParsedContent {
    let document: AIReadableResponseDocument
    let inline: [String: AttributedString]
}

private final class AIResponseParsedContentBox {
    let content: AIResponseParsedContent
    init(_ content: AIResponseParsedContent) { self.content = content }
}

private enum AIResponseParsedContentCache {
    /// 条数上限覆盖长会话的滚动区间；内存压力下系统自动逐出，逐出后最多退回
    /// 「一次后台解析」的行为，不影响正确性。
    static let cache: NSCache<NSString, AIResponseParsedContentBox> = {
        let cache = NSCache<NSString, AIResponseParsedContentBox>()
        cache.countLimit = 300
        return cache
    }()
}

struct AIReadableResponseView: View {
    let text: String
    let isStreaming: Bool
    var isError: Bool = false
    var onRetry: (() -> Void)? = nil

    @State private var isShowingDetails = false
    @State private var cursorVisible = false
    /// 解析后的文档结构（异步解析一次，缓存复用，避免每次 body 都全文重算）
    @State private var document: AIReadableResponseDocument?
    /// 每个 block 文本对应的富文本结果缓存（避免每次 body 重复同步解析 Markdown）
    @State private var inlineCache: [String: AttributedString] = [:]

    /// 本条消息文本在进程缓存中的解析结果（未解析过为 nil）
    private var cachedContent: AIResponseParsedContent? {
        AIResponseParsedContentCache.cache.object(forKey: text as NSString)?.content
    }

    var body: some View {
        Group {
            if isStreaming && text.isEmpty {
                typingIndicator
            } else if isStreaming {
                streamingText
            } else if isError {
                errorContent
            } else {
                readableContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 非流式时异步解析文档 + 预填富文本缓存；流式分支不依赖 document。
        .task(id: text) {
            guard !isStreaming, !isError, !text.isEmpty else {
                document = nil
                inlineCache.removeAll(keepingCapacity: true)
                return
            }
            // 进程缓存命中（第二次及以后进屏）：直接复用，不再后台解析
            if let cached = cachedContent {
                document = cached.document
                inlineCache = cached.inline
                return
            }
            let source = text
            let (parsedDoc, parsedInline) = await Self.parseDocumentAndInline(source)
            guard source == text else { return }
            AIResponseParsedContentCache.cache.setObject(
                AIResponseParsedContentBox(AIResponseParsedContent(document: parsedDoc, inline: parsedInline)),
                forKey: source as NSString
            )
            document = parsedDoc
            inlineCache = parsedInline
        }
    }

    /// 后台解析文档结构 + 预解析所有 block 的行内富文本，一次性返回缓存结果。
    private static func parseDocumentAndInline(
        _ text: String
    ) async -> (AIReadableResponseDocument, [String: AttributedString]) {
        await Task.detached(priority: .utility) {
            let doc = AIReadableResponseParser.parse(text)
            var inline: [String: AttributedString] = [:]
            func cache(_ s: String) {
                guard !s.isEmpty, inline[s] == nil else { return }
                inline[s] = MarkdownAttributedStringRenderer.parseInlineSync(s) ?? AttributedString(s)
            }
            for block in doc.blocks + doc.detailBlocks {
                switch block {
                case .lead(let s), .paragraph(let s), .heading(let s):
                    cache(s)
                case .unorderedList(let items), .orderedList(let items):
                    items.forEach(cache)
                case .table(let header, let rows):
                    header.forEach(cache)
                    rows.forEach { $0.forEach(cache) }
                }
            }
            return (doc, inline)
        }.value
    }

    private var typingIndicator: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.holoTextSecondary.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .modifier(AIReadingDotAnimation(delay: Double(index) * 0.18))
            }
        }
        .padding(.vertical, 8)
        .accessibilityLabel(String(localized: "Holo 正在回复"))
    }

    private var streamingText: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Text(text)
                .font(.body)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            Text("│")
                .font(.body.weight(.medium))
                .foregroundColor(.holoPrimary)
                .opacity(cursorVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                    value: cursorVisible
                )
        }
        .onAppear { cursorVisible = true }
        .onDisappear { cursorVisible = false }
    }

    @ViewBuilder
    private var readableContent: some View {
        // document 解析完成前先纯文本秒开，解析完成后自动升级为结构化富文本。
        // 进程缓存命中（第二次进屏）时不走纯文本兜底，首帧即结构化，高度不跳变。
        if let document {
            structuredContent(document)
        } else if let cached = cachedContent {
            structuredContent(cached.document)
        } else {
            Text(text)
                .font(.body)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func structuredContent(_ document: AIReadableResponseDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            blockList(document.blocks)

            if document.hasDetails {
                detailDisclosure(detailBlocks: document.detailBlocks)
            }
        }
    }

    private var errorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(inlineAttributedString(text))
                .font(.body)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let onRetry {
                Button(action: onRetry) {
                    Label("重新发送", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.holoError)
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "重新发送上一条消息"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.holoError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoError.opacity(0.22), lineWidth: 1)
        }
    }

    private func detailDisclosure(detailBlocks: [AIReadableResponseBlock]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingDetails.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(isShowingDetails ? String(localized: "收起详细分析") : String(localized: "展开更多分析"))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isShowingDetails ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.holoPrimary)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isShowingDetails ? String(localized: "已展开") : String(localized: "已收起"))

            if isShowingDetails {
                blockList(detailBlocks)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func blockList(_ blocks: [AIReadableResponseBlock]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AIReadableResponseBlock) -> some View {
        switch block {
        case .lead(let text):
            Text(inlineAttributedString(text))
                .font(.body.weight(.semibold))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inlineAttributedString(text))
                .font(.body)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .heading(let text):
            Text(inlineAttributedString(text))
                .font(.headline)
                .foregroundColor(.holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .textSelection(.enabled)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.holoPrimary)
                            .frame(width: 5, height: 5)
                        listText(item)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(.holoPrimary)
                            .frame(minWidth: 20, alignment: .trailing)
                        listText(item)
                    }
                }
            }

        case .table(let header, let rows):
            tableBlock(header: header, rows: rows)
        }
    }

    /// AI 表格：竖线表格的自绘卡片。≤4 列均分占满气泡宽度；更宽时横向滚动兜底。
    @ViewBuilder
    private func tableBlock(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)

        if columnCount > 4 {
            ScrollView(.horizontal, showsIndicators: false) {
                tableRows(header: header, rows: rows, columnCount: columnCount, fillsWidth: false)
            }
        } else if columnCount > 0 {
            tableRows(header: header, rows: rows, columnCount: columnCount, fillsWidth: true)
        }
    }

    private func tableRows(
        header: [String],
        rows: [[String]],
        columnCount: Int,
        fillsWidth: Bool
    ) -> some View {
        // Grid 让所有行共享列宽：横滚模式下各行动态内容也不会列错位
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { column in
                    tableCell(
                        column < header.count ? header[column] : "",
                        isHeader: true,
                        fillsWidth: fillsWidth
                    )
                    .background(Color.holoTextPrimary.opacity(0.045))
                }
            }

            tableDividerRow(columnCount: columnCount, color: Color.holoTextPrimary.opacity(0.14))

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    tableDividerRow(columnCount: columnCount, color: Color.holoDivider.opacity(0.75))
                }

                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tableCell(
                            column < row.count ? row[column] : "",
                            isHeader: false,
                            fillsWidth: fillsWidth
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func tableDividerRow(columnCount: Int, color: Color) -> some View {
        GridRow {
            ForEach(0..<columnCount, id: \.self) { _ in
                Rectangle()
                    .fill(color)
                    .frame(height: 0.5)
            }
        }
    }

    @ViewBuilder
    private func tableCell(_ text: String, isHeader: Bool, fillsWidth: Bool) -> some View {
        let content = Text(inlineAttributedString(text))
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .foregroundColor(isHeader ? .holoTextSecondary : .holoTextPrimary)
            .lineSpacing(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

        if fillsWidth {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // 横滚模式：单元格按内容单行展开决定列宽，再拉伸铺满列轨道，
            // 让表头背景在列内无缝连续
            content
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listText(_ text: String) -> some View {
        Text(inlineAttributedString(text))
            .font(.body)
            .foregroundColor(.holoTextPrimary)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func inlineAttributedString(_ text: String) -> AttributedString {
        // 两级缓存：先读本单元格预填缓存，再读进程缓存（@State 被回收后的路径）；
        // 都未命中（错误态等少量路径）才同步解析。
        if let cached = inlineCache[text] {
            return cached
        }
        if let cached = cachedContent?.inline[text] {
            return cached
        }
        let parsed = MarkdownAttributedStringRenderer.parseInlineSync(text) ?? AttributedString(text)
        inlineCache[text] = parsed
        return parsed
    }
}

private struct AIReadingDotAnimation: ViewModifier {
    let delay: Double
    @State private var isBright = false

    func body(content: Content) -> some View {
        content
            .opacity(isBright ? 0.9 : 0.3)
            .animation(
                .easeInOut(duration: 0.65)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: isBright
            )
            .onAppear { isBright = true }
    }
}
