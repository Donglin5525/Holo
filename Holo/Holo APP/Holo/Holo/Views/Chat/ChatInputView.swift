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
        VStack(spacing: 7) {
            if let draft = viewModel.continuationDraft {
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 27, height: 27)
                        .background(Color.holoPrimary.opacity(0.10))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("继续追问这份分析")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.holoPrimary)
                        Text(draft.rootUserQuestion)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.clearContinuationDraft()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消承接上一份分析")
                }
                .padding(.leading, 10)
                .padding(.trailing, 5)
                .padding(.vertical, 6)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.holoPrimary.opacity(0.16), lineWidth: 1)
                )
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
                        // 流式中发送按钮已切换为停止键；回车不允许并发发送第二条消息
                        guard !viewModel.isStreaming else { return }
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

                // 发送/停止按钮：停止键在「普通流式进行中」或「存在等待/恢复中的 Agent 消息」
                // 时都要可见——Agent 等待网络/系统资源期间输入框已解锁可发新消息，但用户
                // 必须始终保有停止入口（cancelStreaming 会取消等待任务并定稿消息）。
                if viewModel.isStreaming || viewModel.hasActiveStreamingMessage {
                    Button {
                        viewModel.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.holoError)
                    }
                    .accessibilityLabel("停止生成")
                } else {
                    Button {
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(sendButtonColor)
                    }
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送消息")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
        .animation(.easeInOut(duration: 0.18), value: viewModel.continuationDraft != nil)
    }

    private var sendButtonColor: Color {
        return viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .holoTextSecondary.opacity(0.3)
            : .holoPrimary
    }

    private var voiceButtonColor: Color {
        viewModel.isStreaming ? .holoTextSecondary.opacity(0.3) : .holoTextSecondary
    }
}
