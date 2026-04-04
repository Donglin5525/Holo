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

    var body: some View {
        if isStreaming {
            // 流式阶段：纯文本 + 闪烁光标
            HStack(spacing: 0) {
                Text(text)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .textSelection(.enabled)

                // 闪烁光标
                Text("|")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
            }
            .onAppear { cursorVisible = true }
        } else {
            // 完成后：Markdown 渲染
            Text(attributedString)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .textSelection(.enabled)
        }
    }

    @State private var cursorVisible = false

    private var attributedString: AttributedString {
        do {
            return try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(text)
        }
    }
}
