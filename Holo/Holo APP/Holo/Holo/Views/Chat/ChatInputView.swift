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

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // 输入框
            TextField("输入消息...", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.holoBody)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .cornerRadius(20)
                .onSubmit {
                    Task { await viewModel.sendMessage() }
                }

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
                        .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .holoPrimary)
                }
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
    }
}
