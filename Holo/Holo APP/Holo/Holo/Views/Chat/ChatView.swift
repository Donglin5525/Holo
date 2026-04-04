//
//  ChatView.swift
//  Holo
//
//  AI 对话主界面
//  消息列表 + 快捷栏 + 输入栏
//

import SwiftUI

struct ChatView: View {

    @StateObject private var viewModel = ChatViewModel()
    @State private var showAISettings = false

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            if !viewModel.isConfigured {
                // 未配置引导
                unconfiguredView
            } else {
                // 对话内容
                chatContent
            }
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
            }
        }
        .onAppear {
            viewModel.configureFromSavedConfig()
        }
    }

    // MARK: - Unconfigured View

    private var unconfiguredView: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoPrimary)

            Text("HOLO AI 对话")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            Text("配置 AI 服务后即可使用\n支持记账、任务、习惯打卡等智能操作")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                showAISettings = true
            } label: {
                Text("配置 AI 服务")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.holoPrimary)
                    .cornerRadius(12)
            }
        }
        .padding()
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            // 消息列表
            messageList

            // 快捷操作栏
            QuickActionBar(viewModel: viewModel)

            // 输入栏
            ChatInputView(viewModel: viewModel)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageBubbleView(
                            message: message,
                            streamingText: viewModel.isStreaming && message.isStreaming ? viewModel.streamingText : nil
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.streamingText) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = viewModel.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}
