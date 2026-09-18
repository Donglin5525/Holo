//
//  GoalWorkshopQuestionCard.swift
//  Holo
//
//  目标共创·问题卡（方案任务 5）：一次一个问题 + 为什么重要 + 跳过
//  2026-09-19 对话感补齐：AI 回应语、用户原话回显、等待状态行——
//  让「发出去」到「下一问」之间不再是一片死寂。
//

import SwiftUI

struct GoalWorkshopQuestionCard: View {
    let question: GoalWorkshopQuestion
    /// 模型最近一轮的回应语（如「明白了，那…」）
    let assistantText: String?
    /// 用户上一轮回答的原话（给下一问做上下文）
    let userReplyText: String?
    /// 刚发出、模型还在处理的回答原话（等待期间回显）
    let pendingReplyText: String?
    let isBusy: Bool
    let onReply: (String) -> Void
    let onSkip: () -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    /// 等待模型时回显刚发出的原话；空闲时回显上一轮原话
    private var echoText: String? {
        if isBusy, let pendingReplyText, !pendingReplyText.isEmpty { return pendingReplyText }
        if !isBusy, let userReplyText, !userReplyText.isEmpty { return userReplyText }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let echoText {
                Label {
                    Text("你刚说：「\(echoText)」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "text.quote")
                        .font(.footnote)
                }
            }
            if let assistantText, !assistantText.isEmpty {
                Text(assistantText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(question.text)
                .font(.headline)
            Label {
                Text(question.whyItMatters)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "questionmark.circle")
                    .font(.footnote)
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Holo 正在想…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("说说你的情况…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(submit)
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button(action: onSkip) {
                    Text("先跳过这个问题")
                        .font(.footnote)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { if !isBusy { focused = true } }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        draft = ""
        onReply(trimmed)
    }
}
