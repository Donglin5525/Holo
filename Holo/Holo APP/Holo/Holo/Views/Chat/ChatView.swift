//
//  ChatView.swift
//  Holo
//
//  AI 对话主界面
//  消息列表 + 快捷栏 + 输入栏
//

import SwiftUI

struct ChatView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChatViewModel()
    @State private var showAISettings = false
    @State private var editingTransaction: Transaction?

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
                                openTransactionDetail(msg)
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
        guard let transactionId = message.linkedTransactionId else { return }
        let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
        editingTransaction = transaction
    }

    // MARK: - Card Tap Navigation

    /// 点击卡片后跳转到对应详情（支持 item 级实体链接）
    private func handleCardTap(message: ChatMessageViewData, cardData: ChatCardData) {
        switch cardData {
        case .transaction:
            // 优先从 executionBatch 的 renderData 中获取 linkedEntityId
            if let entityId = findLinkedEntityId(for: cardData, in: message.executionBatch),
               let uuid = UUID(uuidString: entityId) {
                let transaction = FinanceRepository.shared.findTransaction(by: uuid)
                editingTransaction = transaction
            } else {
                openTransactionDetail(message)
            }
        case .task:
            if let entityId = findLinkedEntityId(for: cardData, in: message.executionBatch),
               let uuid = UUID(uuidString: entityId) {
                DeepLinkState.shared.pendingTarget = .taskDetail(taskId: uuid)
                dismiss()
            } else if let taskId = message.linkedTaskId {
                DeepLinkState.shared.pendingTarget = .taskDetail(taskId: taskId)
                dismiss()
            }
        case .habitCheckIn, .mood, .weight:
            break
        }
    }

    /// 从 executionBatch 中查找对应卡片的 linkedEntityId
    private func findLinkedEntityId(for cardData: ChatCardData, in batch: AIExecutionBatch?) -> String? {
        guard let batch = batch else { return nil }
        let targetIntent: AIIntent
        switch cardData {
        case .transaction: targetIntent = .recordExpense
        case .task: targetIntent = .createTask
        default: return nil
        }
        return batch.items.first { $0.intent == targetIntent && $0.linkedEntityId != nil }?.linkedEntityId
    }
}
