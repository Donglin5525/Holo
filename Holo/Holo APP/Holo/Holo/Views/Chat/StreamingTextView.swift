//
//  StreamingTextView.swift
//  Holo
//
//  流式文本渲染
//  流式阶段纯文本 + 闪烁光标，完成后 Markdown 渲染
//

import SwiftUI

struct StreamingTextView: View {

    let text: String
    let isStreaming: Bool
    @State private var cursorVisible = false
    @State private var renderedMarkdown: AttributedString?

    var body: some View {
        if isStreaming {
            // 流式阶段：纯文本 + 闪烁光标
            HStack(spacing: 0) {
                Text(text)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                // 闪烁光标
                Text("|")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
            }
            .onAppear { cursorVisible = true }
        } else {
            // 完成后：默认先纯文本秒开，短文本再异步升级成 Markdown
            Text(renderedMarkdown ?? AttributedString(text))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .task(id: renderKey) {
                    renderedMarkdown = nil
                    guard shouldRenderMarkdown else { return }

                    let source = text
                    let parsed = await Self.parseMarkdown(source)
                    guard source == text else { return }
                    renderedMarkdown = parsed
                }
        }
    }

    private var renderKey: RenderKey {
        RenderKey(text: text, isStreaming: isStreaming)
    }

    private var shouldRenderMarkdown: Bool {
        !text.isEmpty &&
        text.count <= 2_000 &&
        Self.markdownIndicators.contains { text.contains($0) }
    }

    private static let markdownIndicators = ["**", "`", "#", "- ", "* ", "[", "> "]

    private static func parseMarkdown(_ text: String) async -> AttributedString? {
        await Task.detached(priority: .utility) {
            try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }.value
    }

    private struct RenderKey: Hashable {
        let text: String
        let isStreaming: Bool
    }
}
