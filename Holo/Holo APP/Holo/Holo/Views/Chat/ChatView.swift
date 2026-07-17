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
    #if DEBUG || INTERNAL_DIAGNOSTICS
    @State private var viewingLog: LLMLog?
    #endif
    @State private var didInitialScrollToBottom = false
    @State private var pendingVoiceTranscriptToSend: String?
    @State private var pendingDelete: PendingCardDelete?
    @State private var showDeleteConfirmation = false
    @State private var pendingCategoryEditMessage: ChatMessageViewData?
    @State private var pendingEditPrefill: PendingTransactionPrefill?
    @State private var financeSearchRoute: FlexibleQueryFinanceSearchRoute?
    @State private var memoryInboxNotice: String?
    @Binding var goalPlanningRequest: GoalPlanningRequest?

    /// 外部传入的预填文本（如从记忆长廊"继续问AI"跳转）
    var prefillText: String? = nil
    var opensVoiceInputOnAppear: Bool = false

    private var internalLogAction: ((ChatMessageViewData) -> Void)? {
        #if DEBUG || INTERNAL_DIAGNOSTICS
        return { message in
            viewingLog = HoloInternalLogService.shared.log(for: message.id)
        }
        #else
        return nil
        #endif
    }

    init(
        goalPlanningRequest: Binding<GoalPlanningRequest?> = .constant(nil),
        prefillText: String? = nil,
        opensVoiceInputOnAppear: Bool = false
    ) {
        self._goalPlanningRequest = goalPlanningRequest
        self.prefillText = prefillText
        self.opensVoiceInputOnAppear = opensVoiceInputOnAppear
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
        .overlay(alignment: .top) {
            if let notice = memoryInboxNotice {
                HStack(spacing: HoloSpacing.xs) {
                    Button {
                        HoloMemoryReceiptStore.markWriteReceiptsRead()
                        activeSheet = .memoryCenter
                        memoryInboxNotice = nil
                    } label: {
                        Label(notice, systemImage: "brain.head.profile.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextPrimary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        HoloMemoryReceiptStore.markWriteReceiptsRead()
                        memoryInboxNotice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
                .padding(.top, 58)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let notice = viewModel.memoryNotice {
                Label(notice, systemImage: "brain.head.profile.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: memoryInboxNotice)
        .animation(.easeInOut(duration: 0.2), value: viewModel.memoryNotice)
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            sheetContent(sheet)
        }
        .task {
            await viewModel.setup()
            await loadMemoryInboxNoticeIfNeeded()
            #if DEBUG
            if HoloAppStoreScreenshotSeeder.requestedRoute == .aiAnalysis,
               let message = viewModel.messages.last(where: {
                   $0.metadataState == .loaded && $0.analysisContext != nil
               }) {
                activeSheet = .analysisDetail(message)
            }
            #endif
            if let text = prefillText, !text.isEmpty {
                viewModel.inputText = text
            }
            if opensVoiceInputOnAppear {
                activeSheet = .voiceInput
            }
        }
        .onChange(of: goalPlanningRequest) { _, request in
            guard let request else { return }
            viewModel.startGoalPlanning(seedText: request.seedText)
            goalPlanningRequest = nil
        }
        #if DEBUG || INTERNAL_DIAGNOSTICS
        .fullScreenCover(isPresented: Binding(
            get: { viewingLog != nil },
            set: { if !$0 { viewingLog = nil } }
        )) {
            if let viewingLog {
                ChatLogView(log: viewingLog)
            }
        }
        #endif
        .fullScreenCover(item: $financeSearchRoute) { route in
            FinanceSearchView(
                initialSearchText: route.keyword,
                exactTransactionIDs: route.transactionIDs
            )
        }
        .sheet(isPresented: Binding(
            get: { pendingCategoryEditMessage != nil },
            set: { if !$0 { pendingCategoryEditMessage = nil } }
        )) {
            if let prefill = pendingEditPrefill {
                AddTransactionSheet(
                    editingTransaction: nil,
                    pendingPrefill: prefill
                ) { savedTransaction in
                    if let msg = pendingCategoryEditMessage {
                        viewModel.dismissPendingCardAfterEdit(from: msg, createdTransaction: savedTransaction)
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
        .alert(
            "需要开启 AI 数据处理授权",
            isPresented: $viewModel.showConsentPrompt
        ) {
            Button("去开启") {
                activeSheet = .aiConsent
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(HoloAIDataProcessingConsent.requiredMessage)
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
        .background(Color.holoBackground)
        .zIndex(1)
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

            // 能力入口只在空会话展示，进入对话后让内容与输入框保持安静。
            if viewModel.messages.isEmpty {
                QuickActionBar(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 输入栏
            ChatInputView(
                viewModel: viewModel,
                onVoiceInputTap: {
                    activeSheet = .voiceInput
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.messages.isEmpty)
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

                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        // 时间分隔条：首条消息或距上一条 ≥ 5 分钟时显示（微信风格，非每条都打时间）
                        if ChatTimeStampSeparator.shouldShow(
                            current: message.timestamp,
                            previous: index > 0 ? viewModel.messages[index - 1].timestamp : nil
                        ) {
                            ChatTimeStampSeparator(date: message.timestamp)
                        }

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
                            onFlexibleQueryTransactionTap: { transactionId in
                                openTransactionDetail(transactionId)
                            },
                            onFlexibleQueryViewAllTap: { queryData in
                                openFlexibleQueryResults(queryData)
                            },
                            onViewLog: internalLogAction,
                            onCompactAnalysisTap: {
                                guard message.metadataState == .loaded,
                                      message.analysisContext != nil else { return }
                                activeSheet = .analysisDetail(message)
                            },
                            onAgentDeepAnalysisTap: {
                                guard message.agentResult != nil else { return }
                                activeSheet = .agentDeepAnalysis(message)
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
                                    note: renderData["note"] ?? renderData["categoryCandidate"],
                                    type: type,
                                    category: nil,
                                    date: TransactionDateResolver.resolve(from: renderData)
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
                    // AI 开始回复时自动收起键盘，让用户看到完整内容
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
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
        openTransactionDetail(transactionId)
    }

    private func openTransactionDetail(_ transactionId: UUID) {
        let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
        activeSheet = transaction.map { .editTransaction($0) }
    }

    private func openFlexibleQueryResults(_ data: FlexibleQueryChatCardData) {
        if let route = FlexibleQueryFinanceSearchRoute(cardData: data) {
            financeSearchRoute = route
        } else {
            DeepLinkState.shared.navigate(to: .finance)
            dismiss()
        }
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
        case .analysisSummary, .analysisTrend, .analysisBreakdown, .analysisComparison, .analysisHighlights, .flexibleQuery:
            break
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ChatSheet) -> some View {
        switch sheet {
        case .aiConsent:
            NavigationStack {
                AIDataProcessingConsentView()
            }
        #if DEBUG
        case .aiSettings:
            NavigationStack {
                AISettingsView()
            }
        #endif
        case .editTransaction(let transaction):
            AddTransactionSheet(editingTransaction: transaction) { _ in
                ChatMessageRepository.shared.refreshTransactionCard(transactionId: transaction.id)
            }
        case .analysisDetail(let message):
            AnalysisDetailSheet(message: message)
        case .agentDeepAnalysis(let message):
            if let result = message.agentResult {
                AgentDeepAnalysisDetailSheet(result: result) { drilldown in
                    let keyword = drilldown.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedKeyword = keyword?.isEmpty == false ? keyword : nil
                    DeepLinkState.shared.navigate(to: .financeEvidenceReview(FinanceEvidenceReviewDeepLink(
                        title: normalizedKeyword.map { "\($0)数据依据" } ?? "财务数据依据",
                        label: drilldown.label,
                        keyword: normalizedKeyword,
                        start: drilldown.start,
                        end: drilldown.end,
                        baselineStart: drilldown.baselineStart,
                        baselineEnd: drilldown.baselineEnd,
                        sourceEvidenceID: drilldown.sourceEvidenceID
                    )))
                    dismiss()
                }
            }
        case .memoryCenter:
            NavigationStack {
                HoloMemoryCenterView()
            }
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

    @MainActor
    private func loadMemoryInboxNoticeIfNeeded() async {
        let snapshot = await HoloMemoryReceiptStore.inboxSnapshot()
        guard !snapshot.isEmpty,
              HoloMemoryReceiptStore.shouldPresentSummary() else { return }
        HoloMemoryReceiptStore.markSummaryPresented()
        memoryInboxNotice = snapshot.summaryText
    }
}

private enum ChatSheet: Identifiable {
    case aiConsent
    #if DEBUG
    case aiSettings
    #endif
    case editTransaction(Transaction)
    case analysisDetail(ChatMessageViewData)
    case agentDeepAnalysis(ChatMessageViewData)
    case memoryCenter
    case voiceInput

    var id: String {
        switch self {
        case .aiConsent:
            return "aiConsent"
        #if DEBUG
        case .aiSettings:
            return "aiSettings"
        #endif
        case .editTransaction(let transaction):
            return "editTransaction-\(transaction.id)"
        case .analysisDetail(let message):
            return "analysisDetail-\(message.id)"
        case .agentDeepAnalysis(let message):
            return "agentDeepAnalysis-\(message.id)"
        case .memoryCenter:
            return "memoryCenter"
        case .voiceInput:
            return "voiceInput"
        }
    }
}

nonisolated struct FlexibleQueryFinanceSearchRoute: Identifiable {
    let id = UUID()
    let keyword: String?
    let transactionIDs: [UUID]

    init?(cardData: FlexibleQueryChatCardData) {
        guard !cardData.resultTransactionIDs.isEmpty else { return nil }
        keyword = cardData.searchKeyword
        transactionIDs = cardData.resultTransactionIDs
    }
}

/// 待删除卡片的信息（用于确认弹窗）
private struct PendingCardDelete {
    let category: EntityCategory
    let entityId: UUID
    let description: String
}
