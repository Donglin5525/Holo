//
//  ChatView.swift
//  Holo
//
//  AI 对话主界面
//  消息列表 + 快捷栏 + 输入栏
//

import SwiftUI
import Combine

struct ChatView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChatViewModel()
    @State private var showAISettings = false
    @State private var editingTransaction: Transaction?

    /// 监听记忆长廊"继续问 AI"通知
    @State private var prefillCancellable: AnyCancellable?

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏
                chatNavBar

                if viewModel.isConfigured || !viewModel.hasFinishedSetup || viewModel.didTimeoutLoadingConfig {
                    // 已配置、正在检查中、或检查超时：都允许先进入对话页面，避免首屏卡死
                    chatContent
                } else if !viewModel.isConfigured {
                    // 未配置引导
                    unconfiguredView
                }
            }
        }
        .swipeBackToDismiss {
            dismiss()
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) {}
        }
        .task {
            await viewModel.setup()
            // 监听记忆长廊"继续问 AI"通知
            prefillCancellable = NotificationCenter.default.publisher(
                for: .memoryInsightContinueInChat
            ).sink { notification in
                if let text = notification.userInfo?["prefillText"] as? String {
                    viewModel.inputText = text
                }
            }
        }
    }

    // MARK: - Navigation Bar

    private var chatNavBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoTextSecondary.opacity(0.1))
                    .cornerRadius(16)
            }

            Spacer()

            Text("HOLO AI")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Button {
                showAISettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoTextSecondary.opacity(0.1))
                    .cornerRadius(16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
            if !viewModel.hasFinishedSetup {
                statusBanner("正在读取 AI 配置，你现在也可以直接发送消息")
            } else if viewModel.didTimeoutLoadingConfig {
                statusBanner("AI 配置读取超时，已先放开聊天交互，你也可以点右上角检查设置")
            }

            // 消息列表
            messageList

            // 快捷操作栏
            QuickActionBar(viewModel: viewModel)

            // 输入栏
            ChatInputView(viewModel: viewModel)
        }
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoCardBackground)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageBubbleView(
                            message: message,
                            streamingText: viewModel.isStreaming && message.isStreaming ? viewModel.streamingText : nil,
                            onIntentTagTap: { msg in
                                handleIntentTagTap(msg)
                            },
                            onCardTap: { message, cardData in
                                handleCardTap(message: message, cardData: cardData)
                            }
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

    // MARK: - Transaction Detail

    private func openTransactionDetail(_ message: ChatMessageViewData) {
        guard let transactionId = message.resolveLinkedEntityId(for: .finance) else { return }
        let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
        editingTransaction = transaction
    }

    // MARK: - Intent Tag Navigation

    private func handleIntentTagTap(_ message: ChatMessageViewData) {
        if let transactionId = message.resolveLinkedEntityId(for: .finance) {
            let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
            editingTransaction = transaction
        } else if let taskId = message.resolveLinkedEntityId(for: .task) {
            DeepLinkState.shared.pendingTarget = .taskDetail(taskId: taskId)
            dismiss()
        }
    }

    // MARK: - Card Tap Navigation

    private func handleCardTap(message: ChatMessageViewData, cardData: ChatCardData) {
        switch cardData {
        case .transaction:
            if let transactionId = message.resolveLinkedEntityId(for: .finance) {
                let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
                editingTransaction = transaction
            }
        case .task:
            if let taskId = message.resolveLinkedEntityId(for: .task) {
                DeepLinkState.shared.pendingTarget = .taskDetail(taskId: taskId)
                dismiss()
            }
        case .habitCheckIn, .mood, .weight:
            break
        }
    }
}
