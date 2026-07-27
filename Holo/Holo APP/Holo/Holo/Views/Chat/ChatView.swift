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
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）；
    /// 兼容旧 sheet/cover 场景：未注入时 fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @StateObject private var viewModel = ChatViewModel()
    @State private var activeSheet: ChatSheet?
    #if DEBUG || INTERNAL_DIAGNOSTICS
    @State private var viewingLog: LLMLog?
    #endif
    @State private var didInitialScrollToBottom = false
    /// 加载更早消息时记录的锚点 id（加载前首条 = 用户当时看的那条）。
    /// 待 LazyVStack 插入新行后再 scrollTo，避免在数据刷新前定位不准。
    @State private var pendingEarlierSessionAnchor: UUID?
    /// 长内容收起后请求底层 UIScrollView 校正越界偏移。
    @State private var scrollOffsetClampRequestID = 0
    @State private var pendingVoiceTranscriptToSend: String?
    @State private var pendingDelete: PendingCardDelete?
    @State private var showDeleteConfirmation = false
    @State private var pendingCategoryEditMessage: ChatMessageViewData?
    @State private var pendingEditPrefill: PendingTransactionPrefill?
    @State private var financeSearchRoute: FlexibleQueryFinanceSearchRoute?
    @State private var memoryInboxNotice: String?
    /// 键盘遮挡内容区的高度（已扣除底部 Home Indicator 安全区）。
    /// ZStack 平级常驻模式下祖先视图忽略了键盘安全区，系统自动避让失效，
    /// 因此这里手动监听键盘 frame 变化并给内容加 bottom padding。
    @State private var keyboardOverlap: CGFloat = 0
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
            .padding(.bottom, keyboardOverlap)
        }
        // 关闭系统自动键盘避让（祖先链在 ZStack 常驻模式下已忽略键盘安全区，
        // 系统避让本就到不了这里；统一由上面的 keyboardOverlap padding 手动控制，
        // 避免 sheet/NavigationStack 场景下系统避让与手动 padding 叠加）
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardOverlap(note)
        }
        .swipeBackToDismiss {
            close()
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
        .sheet(isPresented: $viewModel.showPeriodReplayPicker) {
            PeriodReplayPickerSheet { periodType, start, end in
                viewModel.showPeriodReplayPicker = false
                Task { await viewModel.startPeriodReplay(periodType: periodType, start: start, end: end) }
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
                close()
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

            // 消息列表 / 空状态卡片：仅在历史消息加载完成后才显示空状态，
            // 避免进入时「先显示空状态再突然消失」的闪烁。
            if viewModel.isTrulyEmptyConversation {
                ChatEmptyStateView(viewModel: viewModel)
                    .transition(.opacity)
            } else {
                messageList
            }

            // 输入框上方常驻能力行：对话全程可见
            QuickActionBar(viewModel: viewModel)

            // 输入栏
            ChatInputView(
                viewModel: viewModel,
                onVoiceInputTap: {
                    activeSheet = .voiceInput
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isTrulyEmptyConversation)
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
                            onPeriodReplayExpansionChanged: { _, isExpanded in
                                // 长卡片收起后，LazyVStack 可能先卸载越界内容，导致 ScrollViewReader
                                // 找不到消息锚点。改由底层 UIScrollView 按真实 contentSize 校正。
                                guard !isExpanded else { return }
                                scrollOffsetClampRequestID &+= 1
                            },
                            onGoalDraftCardTap: {
                                viewModel.showGoalDraftReview = true
                            },
                            onSavedGoalCardTap: { goalId in
                                // HomeView 监听 deepLinkState 变化后会切换 activeScreen，
                                // ChatView 会自动隐藏，无需手动 dismiss。
                                DeepLinkState.shared.navigate(to: .goalDetail(goalId: goalId))
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
                .background(alignment: .topLeading) {
                    ChatScrollOffsetClampProbe(requestID: scrollOffsetClampRequestID)
                        .frame(width: 1, height: 1)
                }
            }
            .refreshable {
                await triggerLoadEarlier(proxy: proxy)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // 首屏加载完成后滚到底
                if !didInitialScrollToBottom {
                    scrollToBottom(proxy: proxy)
                    didInitialScrollToBottom = true
                    return
                }

                // 加载历史后，待 LazyVStack 插入新行再把视图钉在原看的那条（顶部对齐）。
                // 无动画：插入新行 + scrollTo 重定位叠加动画会闪回，瞬间定位最稳（微信/iMessage 做法）。
                if let anchorId = pendingEarlierSessionAnchor {
                    pendingEarlierSessionAnchor = nil
                    proxy.scrollTo(anchorId, anchor: .top)
                }
            }
            .onChange(of: viewModel.streamingText) { _, _ in
                // 加载历史期间暂停底部自动滚动，避免锚点被流式输出抢走
                guard !viewModel.isApplyingEarlierSession else { return }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                // 加载历史期间即使 isStreaming 翻转也不抢滚动
                guard !viewModel.isApplyingEarlierSession else { return }
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

        // 记下加载前首条消息（用户当前屏幕顶部那条）作为锚点。
        // 加载后视图要钉在这条上，新内容出现在它上方屏幕外。
        let anchorId = viewModel.messages.first?.id

        await viewModel.loadEarlierSession()

        // 不在这里直接 scrollTo：messages 经 receive(on: .main) 异步刷新，
        // 此刻 LazyVStack 还没插入新行，定位会不准。把锚点交给 onChange(messages)，
        // 等数据真正刷新后再定位。
        if anchorId != nil {
            pendingEarlierSessionAnchor = anchorId
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
            // HomeView 监听 deepLinkState 变化后会切换 activeScreen 到 .finance，
            // ChatView 会自动隐藏，无需手动 dismiss。
            DeepLinkState.shared.navigate(to: .finance)
        }
    }

    // MARK: - Keyboard Avoidance

    /// 根据键盘目标 frame 计算其遮挡内容区的高度，并跟随键盘动画曲线更新。
    private func updateKeyboardOverlap(_ note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
        let screenBounds = window?.bounds ?? UIScreen.main.bounds
        let bottomSafeInset = window?.safeAreaInsets.bottom ?? 0

        // 只处理贴底的全宽键盘；浮动/分体键盘（iPad）不做避让
        let isDocked = endFrame.width >= screenBounds.width - 1
        let overlap = isDocked
            ? max(0, screenBounds.maxY - endFrame.minY - bottomSafeInset)
            : 0

        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let animation: Animation
        switch UIView.AnimationCurve(rawValue: curveRaw) {
        case .easeIn: animation = .easeIn(duration: duration)
        case .easeOut: animation = .easeOut(duration: duration)
        case .linear: animation = .linear(duration: duration)
        default: animation = .easeInOut(duration: duration)
        }
        withAnimation(animation) {
            keyboardOverlap = overlap
        }
    }

    // MARK: - Intent Tag Navigation

    private func handleIntentTagTap(_ message: ChatMessageViewData) {
        if let transactionId = message.resolveLinkedEntityId(for: .finance) {
            let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
            activeSheet = transaction.map { .editTransaction($0) }
        } else if let taskId = message.resolveLinkedEntityId(for: .task) {
            // HomeView 监听 deepLinkState 变化后自动切换 activeScreen，ChatView 自动隐藏。
            DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
        } else if message.hasLinkedEntity(for: .memoryInsight) {
            DeepLinkState.shared.navigate(to: .memoryGallery)
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
                // HomeView 监听 deepLinkState 变化后自动切换 activeScreen。
                DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
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
            let originalTransactionID = transaction.id
            AddTransactionSheet(editingTransaction: transaction) { savedTransaction in
                // 回调执行时原交易可能已被转换/删除，不能再读取已删除的 Core Data 对象。
                ChatMessageRepository.shared.refreshTransactionCard(
                    transactionId: savedTransaction?.id ?? originalTransactionID
                )
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
                    // HomeView 监听 deepLinkState 变化后自动切换 activeScreen 到 .finance，ChatView 自动隐藏。
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

/// 观察 SwiftUI 消息列表背后的 UIScrollView。
///
/// 长卡片收起会让 contentSize 在单帧内大幅缩小；UIKit 偶发保留旧 contentOffset，
/// 使整个 LazyVStack 落到视口之外。手动拖动之所以能恢复，是 UIScrollView 在拖动时
/// 会重新把 offset 限制到合法范围。这里监听真实 contentSize，并在折叠请求后主动完成同一校正。
private struct ChatScrollOffsetClampProbe: UIViewRepresentable {
    let requestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.attachIfPossible(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attachIfPossible(from: uiView)
        context.coordinator.handleClampRequest(requestID, from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var lastRequestID = 0
        private var isClampPending = false

        func attachIfPossible(from view: UIView) {
            if let ancestor = enclosingScrollView(from: view) {
                attach(to: ancestor)
                return
            }

            // make/update 时 representable 可能尚未挂到 ScrollView 层级。
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      let ancestor = self.enclosingScrollView(from: view) else { return }
                self.attach(to: ancestor)
                self.clampImmediatelyIfNeeded()
            }
        }

        func handleClampRequest(_ requestID: Int, from view: UIView) {
            guard requestID != lastRequestID else { return }
            lastRequestID = requestID
            isClampPending = true
            attachIfPossible(from: view)

            // 如果 contentSize 已先于 SwiftUI update 完成变化，当前轮直接校正；
            // 否则保留 pending，由 contentSize KVO 在真实缩高发生时校正。
            DispatchQueue.main.async { [weak self] in
                self?.clampImmediatelyIfNeeded()
            }
        }

        func detach() {
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            scrollView = nil
            isClampPending = false
        }

        private func attach(to candidate: UIScrollView) {
            guard scrollView !== candidate else { return }

            contentSizeObservation?.invalidate()
            scrollView = candidate
            contentSizeObservation = candidate.observe(
                \.contentSize,
                options: [.new]
            ) { [weak self] scrollView, _ in
                guard let self, self.isClampPending else { return }
                scrollView.layoutIfNeeded()
                self.clampOffset(in: scrollView)
                self.isClampPending = false
            }
        }

        private func clampImmediatelyIfNeeded() {
            guard isClampPending, let scrollView else { return }
            scrollView.layoutIfNeeded()
            if clampOffset(in: scrollView) {
                isClampPending = false
            }
        }

        @discardableResult
        private func clampOffset(in scrollView: UIScrollView) -> Bool {
            let inset = scrollView.adjustedContentInset
            let minimumX = -inset.left
            let minimumY = -inset.top
            let maximumX = max(
                minimumX,
                scrollView.contentSize.width - scrollView.bounds.width + inset.right
            )
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
            )
            let current = scrollView.contentOffset
            let clamped = CGPoint(
                x: min(max(current.x, minimumX), maximumX),
                y: min(max(current.y, minimumY), maximumY)
            )

            guard abs(clamped.x - current.x) > 0.5
                    || abs(clamped.y - current.y) > 0.5 else {
                // offset 已合法时仍刷新 LazyVStack 的可见区域，避免沿用旧布局缓存。
                scrollView.setNeedsLayout()
                scrollView.layoutIfNeeded()
                return false
            }

            UIView.performWithoutAnimation {
                scrollView.setContentOffset(clamped, animated: false)
                scrollView.setNeedsLayout()
                scrollView.layoutIfNeeded()
            }
            return true
        }

        private func enclosingScrollView(from view: UIView) -> UIScrollView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                ancestor = current.superview
            }
            return nil
        }
    }
}
