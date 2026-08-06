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
            // 编辑提示条：编辑用户消息时显示，明确告知「重发会删除此后的对话」
            if viewModel.editingMessageId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11, weight: .semibold))
                    Text("编辑后重发将删除此后的对话")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("取消") {
                        viewModel.cancelEditing()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                }
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.08))
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
                        sendOrStop()
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
                // P1-6：流式期间若有输入文字，发送按钮变为「中断并发」（先停止再发送）
                if viewModel.isStreaming && hasInputText {
                    Button {
                        sendOrStop()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.holoPrimary)
                    }
                } else if viewModel.isStreaming {
                    Button {
                        viewModel.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.holoError)
                    }
                } else {
                    Button {
                        sendOrStop()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(sendButtonColor)
                    }
                    .disabled(!hasInputText)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
    }

    /// 当前输入框是否有非空文本
    private var hasInputText: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 统一发送入口：编辑模式走截断重发；流式中断并发走先停后发；否则正常发送。
    private func sendOrStop() {
        Task {
            if viewModel.editingMessageId != nil {
                await viewModel.sendMessageWithEditTruncation()
            } else if viewModel.isStreaming {
                // P1-6：中断并发——先停止当前回复（同步释放 UI 态），再发送新消息
                viewModel.cancelStreaming()
                await viewModel.sendMessage()
            } else {
                await viewModel.sendMessage()
            }
        }
    }

    private var sendButtonColor: Color {
        return viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .holoPrimary
    }

    private var voiceButtonColor: Color {
        viewModel.isStreaming ? .gray : .holoTextSecondary
    }
}
