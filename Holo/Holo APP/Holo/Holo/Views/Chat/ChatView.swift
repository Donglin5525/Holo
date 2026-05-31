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
    @State private var activeSheet: ChatSheet?
    @State private var viewingLogMessage: ChatMessageViewData?
    @State private var didInitialScrollToBottom = false
    @State private var pendingVoiceTranscriptToSend: String?
    @State private var pendingDelete: PendingCardDelete?
    @State private var showDeleteConfirmation = false
    @State private var pendingCategoryEditMessage: ChatMessageViewData?
    @State private var pendingEditPrefill: PendingTransactionPrefill?
    @Binding var goalPlanningRequest: GoalPlanningRequest?

    /// 外部传入的预填文本（如从记忆长廊"继续问AI"跳转）
    var prefillText: String? = nil

    init(goalPlanningRequest: Binding<GoalPlanningRequest?> = .constant(nil), prefillText: String? = nil) {
        self._goalPlanningRequest = goalPlanningRequest
        self.prefillText = prefillText
    }

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏
                chatNavBar

                if viewModel.isConfigured || !viewModel.hasFinishedSetup || viewModel.didTimeoutLoadingConfig {
                    // 已连接、正在检查中、或检查超时：都允许先进入对话页面，避免首屏卡死
                    chatContent
                } else if !viewModel.isConfigured {
                    // 服务不可用兜底
                    unconfiguredView
                }
            }
        }
        .swipeBackToDismiss {
            dismiss()
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            sheetContent(sheet)
        }
        .task {
            await viewModel.setup()
            if let text = prefillText, !text.isEmpty {
                viewModel.inputText = text
            }
        }
        .onChange(of: goalPlanningRequest) { _, request in
            guard let request else { return }
            viewModel.startGoalPlanning(seedText: request.seedText)
            goalPlanningRequest = nil
        }
        .fullScreenCover(item: $viewingLogMessage) { message in
            if let log = message.rawLog {
                ChatLogView(log: log)
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingCategoryEditMessage != nil },
            set: { if !$0 { pendingCategoryEditMessage = nil } }
        )) {
            if let prefill = pendingEditPrefill {
                AddTransactionSheet(
                    editingTransaction: nil,
                    pendingPrefill: prefill
                ) {
                    if let msg = pendingCategoryEditMessage {
                        viewModel.dismissPendingCardAfterEdit(from: msg)
                    }
                    pendingCategoryEditMessage = nil
                    pendingEditPrefill = nil
                }
            }
        }
        .confirmationDialog(
            "删除确认",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                executePendingDelete()
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pending = pendingDelete {
                Text("确定删除\(pending.description)吗？此操作不可撤销。")
            }
        }
        .fullScreenCover(isPresented: $viewModel.showGoalDraftReview) {
            if let draft = viewModel.goalDraftForReview {
                GoalDraftReviewView(
                    draft: draft,
                    onCancel: {
                        viewModel.cancelGoalPlanning()
                    },
                    onSaved: { result in
                        viewModel.finishGoalPlanningSave(result)
                    }
                )
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

            #if DEBUG
            Button {
                activeSheet = .aiSettings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoTextSecondary.opacity(0.1))
                    .cornerRadius(16)
            }
            #else
            Color.clear
                .frame(width: 32, height: 32)
            #endif
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

            Text("AI 服务暂时不可用\n请稍后重试或检查网络连接")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !viewModel.hasFinishedSetup {
                statusBanner("正在连接 Holo AI 服务，你现在也可以直接发送消息")
            } else if viewModel.didTimeoutLoadingConfig {
                statusBanner("AI 服务连接较慢，已先放开聊天交互")
            }

            // 消息列表
            messageList

            // 快捷操作栏
            QuickActionBar(viewModel: viewModel)

            // 输入栏
            ChatInputView(
                viewModel: viewModel,
                onVoiceInputTap: {
                    activeSheet = .voiceInput
                }
            )
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
                    // 加载更早会话的入口
                    if viewModel.hasLoadedMessages && viewModel.hasEarlierSessions {
                        loadMoreHeader(proxy: proxy)
                    }

                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageBubbleView(
                            message: message,
                            streamingText: viewModel.isStreaming && message.isStreaming ? viewModel.streamingText : nil,
                            goalDraftForReview: viewModel.goalDraftForReview,
                            onIntentTagTap: { msg in
                                handleIntentTagTap(msg)
                            },
                            onCardTap: { message, cardData in
                                handleCardTap(message: message, cardData: cardData)
                            },
                            onViewLog: { msg in
                                viewingLogMessage = msg
                            },
                            onCompactAnalysisTap: {
                                guard message.metadataState == .loaded,
                                      message.analysisContext != nil else { return }
                                activeSheet = .analysisDetail(message)
                            },
                            onGoalDraftCardTap: {
                                viewModel.showGoalDraftReview = true
                            },
                            onSavedGoalCardTap: { goalId in
                                DeepLinkState.shared.navigate(to: .goalDetail(goalId: goalId))
                                dismiss()
                            },
                            onRetry: {
                                Task { await viewModel.retryMessage(message) }
                            },
                            onCardDelete: { msg, category, description in
                                guard let entityId = msg.resolveLinkedEntityId(for: category) else { return }
                                pendingDelete = PendingCardDelete(
                                    category: category,
                                    entityId: entityId,
                                    description: description
                                )
                                showDeleteConfirmation = true
                            },
                            onTaskConfirm: { msg in
                                viewModel.confirmPendingTask(from: msg)
                            },
                            onTransactionConfirm: { msg in
                                viewModel.confirmPendingTransaction(from: msg)
                            },
                            onTransactionCancel: { msg in
                                viewModel.cancelPendingTransaction(from: msg)
                            },
                            onTransactionModifyCategory: { msg in
                                guard let batch = msg.executionBatch,
                                      let item = batch.items.first(where: { $0.intent.isFinance && $0.renderData?["confirmationStatus"] == "pending" }),
                                      let renderData = item.renderData else { return }
                                let type: TransactionType = item.intent == .recordIncome ? .income : .expense
                                pendingCategoryEditMessage = msg
                                pendingEditPrefill = PendingTransactionPrefill(
                                    amount: renderData["amount"] ?? "0",
                                    note: renderData["note"],
                                    type: type,
                                    category: nil
                                )
                            }
                        )
                        .id(message.id)
                        .onAppear {
                            viewModel.loadMetadataIfNeeded(for: message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable {
                await triggerLoadEarlier(proxy: proxy)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if !didInitialScrollToBottom {
                    scrollToBottom(proxy: proxy)
                    didInitialScrollToBottom = true
                }
            }
            .onChange(of: viewModel.streamingText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming {
                    scrollToBottom(proxy: proxy)
                }
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

    // MARK: - Load More Header

    @ViewBuilder
    private func loadMoreHeader(proxy: ScrollViewProxy) -> some View {
        Button {
            Task {
                await triggerLoadEarlier(proxy: proxy)
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isLoadingEarlierSession {
                    ProgressView()
                        .scaleEffect(0.65)
                    Text("正在加载更早的消息")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    Text("加载更早的消息")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingEarlierSession)
    }

    private func triggerLoadEarlier(proxy: ScrollViewProxy) async {
        guard didInitialScrollToBottom,
              viewModel.hasEarlierSessions,
              !viewModel.isLoadingEarlierSession else { return }

        if let anchorId = await viewModel.loadEarlierSession() {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(anchorId, anchor: .top)
            }
        }
    }

    // MARK: - Transaction Detail

    private func openTransactionDetail(_ message: ChatMessageViewData) {
        guard let transactionId = message.resolveLinkedEntityId(for: .finance) else { return }
        let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
        activeSheet = transaction.map { .editTransaction($0) }
    }

    // MARK: - Intent Tag Navigation

    private func handleIntentTagTap(_ message: ChatMessageViewData) {
        if let transactionId = message.resolveLinkedEntityId(for: .finance) {
            let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
            activeSheet = transaction.map { .editTransaction($0) }
        } else if let taskId = message.resolveLinkedEntityId(for: .task) {
            DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
            dismiss()
        } else if message.hasLinkedEntity(for: .memoryInsight) {
            DeepLinkState.shared.navigate(to: .memoryGallery)
            dismiss()
        }
    }

    // MARK: - Card Tap Navigation

    // MARK: - Card Delete

    private func executePendingDelete() {
        guard let pending = pendingDelete else { return }
        let category = pending.category
        let entityId = pending.entityId
        pendingDelete = nil

        switch category {
        case .finance:
            if let transaction = FinanceRepository.shared.findTransaction(by: entityId) {
                Task {
                    try? await FinanceRepository.shared.deleteTransaction(transaction)
                }
            }
        case .task:
            if let task = TodoRepository.shared.findTask(by: entityId) {
                try? TodoRepository.shared.deleteTask(task)
            }
        default:
            break
        }
    }

    // MARK: - Original Card Tap Navigation

    private func handleCardTap(message: ChatMessageViewData, cardData: ChatCardData) {
        switch cardData {
        case .transaction:
            if let transactionId = message.resolveLinkedEntityId(for: .finance) {
                let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
                activeSheet = transaction.map { .editTransaction($0) }
            }
        case .task:
            if let taskId = message.resolveLinkedEntityId(for: .task) {
                DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
                dismiss()
            }
        case .habitCheckIn, .mood, .weight:
            break
        case .analysisSummary, .analysisTrend, .analysisBreakdown, .analysisComparison, .analysisHighlights:
            break
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ChatSheet) -> some View {
        switch sheet {
        case .aiSettings:
            NavigationStack {
                AISettingsView()
            }
        case .editTransaction(let transaction):
            AddTransactionSheet(editingTransaction: transaction) {
                ChatMessageRepository.shared.refreshTransactionCard(transactionId: transaction.id)
            }
        case .analysisDetail(let message):
            AnalysisDetailSheet(message: message)
        case .voiceInput:
            VoiceInputSheet(speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider()) { transcript in
                pendingVoiceTranscriptToSend = transcript
                activeSheet = nil
            }
        }
    }

    private func handleSheetDismiss() {
        guard let transcript = pendingVoiceTranscriptToSend?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !transcript.isEmpty else {
            pendingVoiceTranscriptToSend = nil
            return
        }

        pendingVoiceTranscriptToSend = nil
        viewModel.inputText = transcript
        Task { await viewModel.sendMessage() }
    }
}

private enum ChatSheet: Identifiable {
    case aiSettings
    case editTransaction(Transaction)
    case analysisDetail(ChatMessageViewData)
    case voiceInput

    var id: String {
        switch self {
        case .aiSettings:
            return "aiSettings"
        case .editTransaction(let transaction):
            return "editTransaction-\(transaction.id)"
        case .analysisDetail(let message):
            return "analysisDetail-\(message.id)"
        case .voiceInput:
            return "voiceInput"
        }
    }
}

/// 待删除卡片的信息（用于确认弹窗）
private struct PendingCardDelete {
    let category: EntityCategory
    let entityId: UUID
    let description: String
}
