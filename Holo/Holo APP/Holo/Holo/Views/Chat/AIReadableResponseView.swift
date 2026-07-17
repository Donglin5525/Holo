//
//  AIReadableResponseView.swift
//  Holo
//
//  AI 普通回答的通用阅读视图：文字为底座，结构按需增强。
//

import SwiftUI

struct AIReadableResponseView: View {
    let text: String
    let isStreaming: Bool
    var isError: Bool = false
    var onRetry: (() -> Void)? = nil

    @State private var isShowingDetails = false
    @State private var cursorVisible = false

    private var document: AIReadableResponseDocument {
        AIReadableResponseParser.parse(text)
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
        .accessibilityLabel("Holo 正在回复")
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

    private var readableContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            blockList(document.blocks)

            if document.hasDetails {
                detailDisclosure
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
                .accessibilityHint("重新发送上一条消息")
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

    private var detailDisclosure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isShowingDetails.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(isShowingDetails ? "收起详细分析" : "展开更多分析")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isShowingDetails ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.holoPrimary)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isShowingDetails ? "已展开" : "已收起")

            if isShowingDetails {
                blockList(document.detailBlocks)
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
        MarkdownAttributedStringRenderer.parseInlineSync(text) ?? AttributedString(text)
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
