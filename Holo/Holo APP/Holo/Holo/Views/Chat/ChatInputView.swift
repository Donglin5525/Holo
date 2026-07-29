//
//  ChatInputView.swift
//  Holo
//
//  对话输入栏
//  TextField + 发送/停止按钮
//

import SwiftUI

struct ChatInputView: View {

    @ObservedObject var viewModel: ChatViewModel
    let onVoiceInputTap: () -> Void

    init(
        viewModel: ChatViewModel,
        onVoiceInputTap: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onVoiceInputTap = onVoiceInputTap
    }

    var body: some View {
        VStack(spacing: 0) {
            // 追问锚定条：非 nil 时展示在输入框上方，提示当前输入将承接哪份分析。
            if let draft = viewModel.continuationDraft {
                continuationAnchorBar(draft)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 12) {
                // 输入框
                TextField("输入消息...", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.holoBody)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.holoCardBackground)
                    .cornerRadius(20)
                    .onSubmit {
                        Task { await viewModel.sendMessage() }
                    }

                Button {
                    onVoiceInputTap()
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(voiceButtonColor)
                }
                .disabled(viewModel.isStreaming)
                .accessibilityLabel("语音输入")

                // 发送/停止按钮
                if viewModel.isStreaming {
                    Button {
                        viewModel.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.red)
                    }
                } else {
                    Button {
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(sendButtonColor)
                    }
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.continuationDraft != nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
    }

    /// 追问锚定条：展示根问题摘要 + 取消按钮。
    @ViewBuilder
    private func continuationAnchorBar(_ draft: HoloAgentContinuationDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text(draft.relation.shortLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.holoPrimary)
                Text(draft.rootUserQuestion)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button {
                viewModel.clearContinuationDraft()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消追问锚定")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.holoPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.12), lineWidth: 1)
        )
        .padding(.bottom, 8)
    }

    private var sendButtonColor: Color {
        return viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .holoPrimary
    }

    private var voiceButtonColor: Color {
        viewModel.isStreaming ? .gray : .holoTextSecondary
    }
}
