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
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）；
    /// 兼容旧 sheet/cover 场景：未注入时 fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var scrollController = ChatScrollController()
    /// AI 数据处理授权状态：未授权时首屏给出准确引导，授权后实时切回对话页
    @ObservedObject private var consent = HoloAIDataProcessingConsent.shared
    @State private var activeSheet: ChatSheet?
    #if DEBUG || INTERNAL_DIAGNOSTICS
    @State private var viewingLog: LLMLog?
    #endif
    @State private var didInitialScrollToBottom = false
    /// 首次进入时先让历史消息在不可见状态完成布局和回底，避免与页面滑入转场叠加。
    @State private var isInitialConversationVisible = false
    @State private var initialPresentationStartedAt = Date()
    @State private var historyLoadGate = ChatHistoryLoadGate()
    @State private var pendingNewMessageCount = 0
    @State private var hasUnseenStreamingUpdate = false
    @State private var pendingVoiceTranscriptToSend: String?
    @State private var pendingDelete: PendingCardDelete?
    @State private var showDeleteConfirmation = false
    @State private var pendingCategoryEditMessage: ChatMessageViewData?
    /// 正在改分类的待确认项 ID：多卡消息里 dismiss 时按它定位，避免误关第一张 pending 卡
    @State private var pendingCategoryEditItemID: String?
    @State private var pendingEditPrefill: PendingTransactionPrefill?
    @State private var financeSearchRoute: FlexibleQueryFinanceSearchRoute?
    @State private var memoryInboxNotice: String?
    /// 待举报的 AI 消息（驱动 ContentReportSheet）
    @State private var reportingMessage: ChatMessageViewData?
    /// 额度耗尽卡片「了解 Holo Plus」触发，sheet 呈现会员中心
    @State private var showMembershipCenter = false
    /// 键盘遮挡内容区的高度（已扣除底部 Home Indicator 安全区）。
    /// ZStack 平级常驻模式下祖先视图忽略了键盘安全区，系统自动避让失效，
    /// 因此这里手动监听键盘 frame 变化并给内容加 bottom padding。
    @State private var keyboardOverlap: CGFloat = 0
    @Binding var goalPlanningRequest: GoalPlanningRequest?
    /// 跨模块洞察直达（首页胶囊 / 系统通知）：消费 .memoryInsight 深链
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    // MARK: 页内双 Tab（对话 / 报告）——设计文档 §4.1

    private enum ChatPageTab {
        case chat
        case report
    }

    @State private var selectedPageTab: ChatPageTab = .chat
    /// 报告 pane 首次切换才构建（聊天页性能保护），之后常驻不销毁
    @State private var hasVisitedReportTab = false
    @StateObject private var reportViewModel = ChatReportTabViewModel()
    /// 报告详情（全屏）：报告 Tab 档案行 / 聊天分析卡 / 长廊门卡三处共用
    @State private var agentDetailMessage: ChatMessageViewData?
    /// 回放阅读版（全屏）：报告 Tab 档案行进入
    @State private var replayReaderMessage: ChatMessageViewData?

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

                if !consent.isGranted {
                    // 未开启 AI 数据处理授权：首屏给出准确引导，避免误导性的「服务不可用」
                    unconfiguredView
                } else if viewModel.isConfigured || !viewModel.hasFinishedSetup || viewModel.didTimeoutLoadingConfig {
                    // 已连接、正在检查中、或检查超时：都允许先进入对话页面，避免首屏卡死
                    pageTabBar
                    pageTabContent
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
        .swipeBackToDismiss(isResidentScreenRoot: true) {
            viewModel.clearContinuationDraft()
            close()
        }
        .overlay(alignment: .top) {
            if let notice = memoryInboxNotice {
                HStack(spacing: HoloSpacing.xs) {
                    Button {
                        HoloMemoryReceiptStore.markWriteReceiptsRead()
                        memoryInboxNotice = nil
                        DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: true))
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
        .sheet(isPresented: $showMembershipCenter) {
            NavigationStack {
                HoloMembershipCenterView()
            }
        }
        .sheet(item: $reportingMessage) { message in
            ContentReportSheet(message: message)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await viewModel.setup()
            await loadMemoryInboxNoticeIfNeeded()
            reportViewModel.bind(chatViewModel: viewModel)
            // 跨模块请求切报告 Tab（聊天卡回执 / 长廊门卡）：常驻页用 onReceive 消费，
            // 首次创建时补消费冷启动前发出的请求
            if ChatReportTabRouter.shared.consumePendingRequest() {
                switchToReportTab()
            }
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
            consumeInsightDeepLink()
        }
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            consumeInsightDeepLink()
        }
        .onReceive(ChatReportTabRouter.shared.$requestTicket.dropFirst()) { _ in
            // dropFirst：@Published 订阅时会先回放当前值，不滤掉会把
            // 「进入页面」误判成一次跳转请求，导致默认落在报告 Tab。
            switchToReportTab()
        }
        .task(id: viewModel.hasLoadedMessages) {
            await revealInitialConversationIfReady()
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
            set: { if !$0 { pendingCategoryEditMessage = nil; pendingCategoryEditItemID = nil } }
        )) {
            if let prefill = pendingEditPrefill {
                AddTransactionSheet(
                    editingTransaction: nil,
                    pendingPrefill: prefill
                ) { savedTransaction in
                    if let msg = pendingCategoryEditMessage {
                        viewModel.dismissPendingCardAfterEdit(
                            from: msg,
                            itemID: pendingCategoryEditItemID,
                            createdTransaction: savedTransaction
                        )
                    }
                    pendingCategoryEditMessage = nil
                    pendingCategoryEditItemID = nil
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
        // 报告详情：从 activeSheet 枚举迁出为独立全屏层（设计文档 §4.3）。
        // 迁移原因：详情从「下拉即关的浮层」升级为正式全屏页；独立 item 绑定 +
        // onDismiss 复位，不与既有 5 sheet + 3 cover 的状态机互相干扰。
        // 统一走 ReportDetailRoute：详情内可直接追问（不弹回对话页），
        // 追问出的新报告挂进本报告的追问记录。
        .fullScreenCover(item: $agentDetailMessage, onDismiss: {
            agentDetailMessage = nil
        }) { message in
            ReportDetailRoute(
                message: message,
                chatViewModel: viewModel,
                onFinanceDrilldown: { drilldown in
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
            )
        }
        .fullScreenCover(item: $replayReaderMessage) { message in
            ReportReplayReaderView(message: message)
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
        .fullScreenCover(isPresented: $viewModel.showLifePlanReview) {
            if let snapshot = viewModel.lifePlanForReview {
                LifePlanReviewView(
                    snapshot: snapshot,
                    onConfirm: { selection in
                        confirmLifePlanSelection(selection)
                    },
                    onCancel: {
                        viewModel.lifePlanForReview = nil
                        viewModel.showLifePlanReview = false
                    }
                )
            }
        }
    }

    // MARK: - Navigation Bar

    private var chatNavBar: some View {
        HStack {
            Button {
                viewModel.clearContinuationDraft()
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
            Image(systemName: consent.isGranted ? "bubble.left.and.bubble.right.fill" : "lock.shield.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoPrimary)

            Text("HOLO AI 对话")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            if consent.isGranted {
                // 已授权但服务不可用：保留网络提示
                Text("AI 服务暂时不可用\n请稍后重试或检查网络连接")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)
            } else {
                // 未授权：说明真实原因并提供开启入口
                Text("你还未开启 AI 数据处理授权\n开启后即可使用")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    activeSheet = .aiConsent
                } label: {
                    Text("开启授权")
                        .font(.holoBody.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.holoPrimary, in: Capsule())
                }
            }
        }
        .padding()
    }

    // MARK: - 页内双 Tab（对话 / 报告）

    private var pageTabBar: some View {
        HStack(spacing: 0) {
            pageTabButton(.chat, title: "对话", showsDot: false)
            pageTabButton(.report, title: "报告", showsDot: reportViewModel.hasUnreadReport)
        }
        .frame(width: 190)
        .padding(3)
        .background(Color.holoTextSecondary.opacity(0.09), in: Capsule())
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func pageTabButton(_ tab: ChatPageTab, title: String, showsDot: Bool) -> some View {
        let isSelected = selectedPageTab == tab
        return Button {
            guard selectedPageTab != tab else { return }
            if tab == .report {
                switchToReportTab()
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedPageTab = .chat
                }
                reportViewModel.markHidden()
            }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? Color.holoCardBackground : .clear, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle()
                            .fill(Color.holoPrimary)
                            .frame(width: 7, height: 7)
                            .offset(x: -6, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 两 Tab 常驻不销毁（照搬记忆长廊 tabContent 模式）：
    /// 切走仅隐藏，聊天侧滚动位置与输入态跨切换存活。
    /// 报告 pane 延迟到首次切换才构建，避免加重聊天首帧。
    private var pageTabContent: some View {
        ZStack {
            chatContent
                .opacity(selectedPageTab == .chat ? 1 : 0)
                .allowsHitTesting(selectedPageTab == .chat)
                .accessibilityHidden(selectedPageTab != .chat)

            if hasVisitedReportTab {
                ChatReportTabView(
                    viewModel: reportViewModel,
                    onOpenEntry: { entry in
                        openReportEntry(entry)
                    },
                    onLaunchInChat: {
                        // 空态橱窗 CTA：切回对话并打开场景面板——
                        // 新用户第一发起就看到全部能力目录，比静默预填一句更有教育意义
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedPageTab = .chat
                        }
                        reportViewModel.markHidden()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            viewModel.showAnalysisScenarioPanel = true
                        }
                    }
                )
                .opacity(selectedPageTab == .report ? 1 : 0)
                .allowsHitTesting(selectedPageTab == .report)
                .accessibilityHidden(selectedPageTab != .report)
            }
        }
    }

    private func switchToReportTab() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedPageTab = .report
        }
        hasVisitedReportTab = true
        reportViewModel.markSeen()
        Task { await reportViewModel.reload() }
        viewModel.showAnalysisScenarioPanel = false
        // 隐藏的聊天 pane 不会自动释放第一响应者，切走时手动收起键盘
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// 消费 .memoryInsight 深链（首页洞察胶囊 / 系统通知）：
    /// 在聊天流直接打开该洞察的回放卡片，落已读后首页胶囊让位下一条候选。
    /// 无论目标洞察是否还可用都先清空 pendingTarget，避免残留目标反复触发导航。
    private func consumeInsightDeepLink() {
        guard case .memoryInsight(let insightId) = deepLinkState.pendingTarget else { return }
        deepLinkState.pendingTarget = nil
        selectedPageTab = .chat
        Task {
            await viewModel.openScheduledInsight(id: insightId)
        }
    }

    /// 档案行点击分流：深度分析 → 全屏报告详情；周期回放 → 全屏阅读版。
    private func openReportEntry(_ entry: ChatMessageRepository.ReportArchiveDTO) {
        guard let message = reportViewModel.loadReportMessage(id: entry.id) else { return }
        switch entry.kind {
        case .deepAnalysis:
            agentDetailMessage = message
        case .periodReplay:
            replayReaderMessage = message
        }
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
            Group {
                if viewModel.isTrulyEmptyConversation {
                    ChatEmptyStateView(viewModel: viewModel)
                        .transition(.opacity)
                } else {
                    messageList
                }
            }
            // opacity 不参与布局：消息和复杂卡片会在不可见状态完成首轮测量，
            // reveal 时只切换可见性，不再触发第二次位移。
            .opacity(isInitialConversationVisible ? 1 : 0)
            .allowsHitTesting(isInitialConversationVisible)
            .accessibilityHidden(!isInitialConversationVisible)

            // 输入框上方常驻能力行：对话全程可见
            QuickActionBar(viewModel: viewModel)

            // 「深度分析」胶囊展开的场景面板（甲方案）：选场景只预填问句，发送由用户确认
            if viewModel.showAnalysisScenarioPanel {
                AnalysisScenarioPanel { scenario in
                    viewModel.selectAnalysisScenario(scenario)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 流式超时未完成的工作中提示（watchdog 第一段触发）：让用户知道 AI 没有卡死
            if let hint = viewModel.streamingStatusHint, viewModel.isStreaming {
                Label(hint, systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            // 场景预填来源提示：用户改写问句/发送后自动消失（见 VM 计算属性）
            if let scenarioTitle = viewModel.activeScenarioPrefillTitle {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("来自「\(scenarioTitle)」场景 · 可改写问句，确认后发送")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.holoPrimary.opacity(0.95))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.holoPrimary.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.22), lineWidth: 0.8))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .transition(.opacity)
            }

            // 输入栏
            ChatInputView(
                viewModel: viewModel,
                onVoiceInputTap: {
                    activeSheet = .voiceInput
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isTrulyEmptyConversation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.streamingStatusHint)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.showAnalysisScenarioPanel)
        .animation(.easeInOut(duration: 0.18), value: viewModel.activeScenarioPrefillTitle)
        .onChange(of: viewModel.showAnalysisScenarioPanel) { _, isOpen in
            // 面板展开时收起键盘，保证场景目录完整可见
            if isOpen {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
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
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if viewModel.hasLoadedMessages
                    && (viewModel.hasEarlierSessions
                        || viewModel.isLoadingEarlierSession
                        || viewModel.earlierHistoryLoadFailed) {
                    historyLoadingHeader
                }

                ForEach(viewModel.messages, id: \.id) { message in
                    if message.showsTimestampSeparator {
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
                            agentDetailMessage = message
                        },
                        onAgentScopeChange: { preset in
                            guard let result = message.agentResult else { return }
                            Task { await viewModel.changeAnalysisScope(from: result, preset: preset) }
                        },
                        onAgentResumePaused: {
                            viewModel.resumePausedAgentJobs(sourceMessageID: message.id)
                        },
                        onPeriodReplayExpansionChanged: { _, isExpanded in
                            guard !isExpanded else { return }
                            scrollController.requestOffsetClamp()
                        },
                        onGoalDraftCardTap: {
                            viewModel.showGoalDraftReview = true
                        },
                        onSavedGoalCardTap: { goalId in
                            DeepLinkState.shared.navigate(to: .goalDetail(goalId: goalId))
                        },
                        onRetry: {
                            Task { await viewModel.retryMessage(message) }
                        },
                        onLearnPlus: {
                            showMembershipCenter = true
                        },
                        onCardDelete: { msg, entityId, category, description in
                            pendingDelete = PendingCardDelete(
                                category: category,
                                entityId: entityId,
                                description: description
                            )
                            showDeleteConfirmation = true
                        },
                        onTaskConfirm: { msg, taskData in
                            viewModel.confirmPendingTask(from: msg, itemID: taskData.itemID)
                        },
                        onTaskCancel: { msg, taskData in
                            viewModel.cancelPendingTask(from: msg, itemID: taskData.itemID)
                        },
                        onTaskFollowUp: { msg, taskData in
                            viewModel.startTaskFollowUp(taskData)
                        },
                        onTransactionConfirm: { msg, txData in
                            viewModel.confirmPendingTransaction(from: msg, itemID: txData.itemID)
                        },
                        onTransactionCancel: { msg, txData in
                            viewModel.cancelPendingTransaction(from: msg, itemID: txData.itemID)
                        },
                        onTransactionModifyCategory: { msg, txData in
                            // 按 itemID 定位被点击卡片的待确认项；确认进行中的项不允许再改分类
                            guard let pending = viewModel.pendingFinanceItem(in: msg, itemID: txData.itemID),
                                  let renderData = pending.renderData else { return }
                            let type: TransactionType = pending.intent == .recordIncome ? .income : .expense
                            pendingCategoryEditMessage = msg
                            pendingCategoryEditItemID = pending.id
                            pendingEditPrefill = PendingTransactionPrefill(
                                amount: renderData["amount"] ?? "0",
                                note: renderData["note"] ?? renderData["categoryCandidate"],
                                type: type,
                                category: nil,
                                date: TransactionDateResolver.resolve(from: renderData)
                            )
                        },
                        onBudgetConfirm: { msg, budgetData in
                            viewModel.confirmPendingBudget(from: msg, itemID: budgetData.itemID)
                        },
                        onBudgetCancel: { msg, budgetData in
                            viewModel.cancelPendingBudget(from: msg, itemID: budgetData.itemID)
                        },
                        onAnniversaryConfirm: { msg, anniversaryData in
                            viewModel.confirmPendingAnniversary(from: msg, itemID: anniversaryData.itemID)
                        },
                        onAnniversaryCancel: { msg, anniversaryData in
                            viewModel.cancelPendingAnniversary(from: msg, itemID: anniversaryData.itemID)
                        },
                        onGoalChoiceSelect: { msg, choiceData, candidate in
                            viewModel.confirmPendingGoalChoice(
                                from: msg,
                                itemID: choiceData.itemID,
                                goalId: candidate.goalId
                            )
                        },
                        onGoalChoiceCancel: { msg, choiceData in
                            viewModel.cancelPendingGoalChoice(from: msg, itemID: choiceData.itemID)
                        },
                        onReport: { msg in
                            reportingMessage = msg
                        },
                        lifePlanSnapshotProvider: { msg in
                            viewModel.lifePlanSnapshot(for: msg)
                        },
                        lifePlanUndoPlanID: viewModel.lastPlanUndo?.planID,
                        onLifePlanOpenReview: { snapshot in
                            viewModel.openLifePlanReview(snapshot)
                        },
                        onLifePlanUndo: { snapshot in
                            if let undo = viewModel.lastPlanUndo, undo.planID == snapshot.id {
                                viewModel.undoLifePlanConfirm(planID: undo.planID, token: undo.token)
                            }
                        }
                    )
                    .equatable()
                    .id(message.id)
                    .onAppear {
                        viewModel.loadMetadataIfNeeded(for: message.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // 返回最下方按钮出现时，底部留出避让空间，最后一张卡片不被按钮胶囊盖住。
            .padding(.bottom, scrollController.viewport.showsJumpToLatest ? 64 : 12)
            .background(alignment: .topLeading) {
                ChatScrollViewBridge(controller: scrollController)
                    .frame(width: 1, height: 1)
                ChatScrollIndicator()
                    .frame(width: 1, height: 1)
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottomTrailing) {
            if scrollController.viewport.showsJumpToLatest {
                jumpToLatestButton
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .animation(
            .spring(response: 0.28, dampingFraction: 0.82),
            value: scrollController.viewport.showsJumpToLatest
        )
        .onAppear {
            performInitialScrollIfNeeded()
        }
        .onChange(of: messageListSignature) { previous, current in
            handleMessageListMutation(previous: previous, current: current)
        }
        .onChange(of: scrollController.viewport) { _, viewport in
            handleViewportChange(viewport)
        }
        .onChange(of: viewModel.streamingText) { _, _ in
            if scrollController.viewport.showsJumpToLatest {
                hasUnseenStreamingUpdate = true
            }
        }
        .onChange(of: viewModel.isStreaming) { _, streaming in
            guard streaming else { return }
            // AI 开始回复时收起键盘；是否跟随到底部由当前视口决定，不打断历史浏览。
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            if scrollController.viewport.isNearBottom {
                scrollController.scrollToBottom(animated: false)
            }
        }
    }

    // MARK: - IM Scroll Behavior

    @ViewBuilder
    private var historyLoadingHeader: some View {
        Group {
            if viewModel.isLoadingEarlierSession {
                HStack(spacing: 7) {
                    ProgressView()
                        .scaleEffect(0.68)
                    Text("正在加载更早的消息")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
                .transition(.opacity)
            } else if viewModel.earlierHistoryLoadFailed {
                Button {
                    Task {
                        await triggerLoadEarlier()
                    }
                } label: {
                    Label("加载失败，点击重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            } else {
                // 视觉上保持成熟 IM 的无按钮顶部；同时保留点击和 VoiceOver 的分页入口。
                Button {
                    Task {
                        await triggerLoadEarlier()
                    }
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("加载更早的消息")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .animation(.easeOut(duration: 0.16), value: viewModel.isLoadingEarlierSession)
        .animation(.easeOut(duration: 0.16), value: viewModel.earlierHistoryLoadFailed)
    }

    private var jumpToLatestButton: some View {
        Button {
            pendingNewMessageCount = 0
            hasUnseenStreamingUpdate = false
            scrollController.scrollToBottom(animated: true)
        } label: {
            HStack(spacing: pendingLatestActivityCount > 0 ? 6 : 0) {
                if pendingLatestActivityCount > 0 {
                    Text(pendingLatestActivityCount > 99 ? "99+" : "\(pendingLatestActivityCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.holoPrimary, in: Capsule())
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, pendingLatestActivityCount > 0 ? 7 : 0)
        .padding(.trailing, pendingLatestActivityCount > 0 ? 2 : 0)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.holoTextSecondary.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .contentShape(Capsule())
        .accessibilityLabel(
            pendingLatestActivityCount > 0
                ? "回到最新消息，\(pendingLatestActivityCount) 条新消息"
                : "回到最新消息"
        )
    }

    private var pendingLatestActivityCount: Int {
        max(pendingNewMessageCount, hasUnseenStreamingUpdate ? 1 : 0)
    }

    /// 只读取 count/首尾 ID，避免流式输出每个 token 都复制整份消息 ID 数组。
    private var messageListSignature: ChatMessageListSignature {
        ChatMessageListSignature(
            count: viewModel.messages.count,
            firstID: viewModel.messages.first?.id,
            lastID: viewModel.messages.last?.id
        )
    }

    private func performInitialScrollIfNeeded() {
        guard !didInitialScrollToBottom,
              !viewModel.messages.isEmpty else { return }
        didInitialScrollToBottom = true
        pendingNewMessageCount = 0
        hasUnseenStreamingUpdate = false
        scrollController.scrollToBottom(animated: false)
    }

    /// 首屏内容采用“先布局、后展示”的原子呈现：
    /// 1. 等历史消息读取完成；2. 在不可见状态完成回底和复杂卡片测量；
    /// 3. 等页面滑入转场结束；4. 禁用隐式动画后一次性展示。
    @MainActor
    private func revealInitialConversationIfReady() async {
        guard viewModel.hasLoadedMessages,
              !isInitialConversationVisible else { return }

        if !viewModel.messages.isEmpty {
            // 第一次调用建立底部目标，第二次调用消费首轮 LazyVStack 高度修正。
            scrollController.scrollToBottom(animated: false)
            await Task.yield()
            try? await Task.sleep(
                nanoseconds: ChatInitialPresentationPolicy.layoutSettlingNanoseconds
            )
            guard !Task.isCancelled else { return }
            scrollController.scrollToBottom(animated: false)
            await Task.yield()
        }

        let remainingDelay = ChatInitialPresentationPolicy.remainingTransitionDelay(
            startedAt: initialPresentationStartedAt,
            now: Date(),
            screenTransitionDuration: HoloScreenTransitionMetrics.duration
        )
        if remainingDelay > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(remainingDelay * 1_000_000_000)
            )
        }
        guard !Task.isCancelled else { return }

        var transaction = SwiftUI.Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInitialConversationVisible = true
        }
    }

    private func handleMessageListMutation(
        previous: ChatMessageListSignature,
        current: ChatMessageListSignature
    ) {
        let mutation = ChatMessageListMutation.classify(
            previous: previous,
            current: current
        )

        switch mutation {
        case .unchanged:
            break

        case .initial(let count):
            guard count > 0 else { return }
            performInitialScrollIfNeeded()

        case .prepended:
            // 仅在 prepend 已发生、但新布局尚未落地的窗口开启保护。
            // 避免异步查询期间把底部流式增长误当成顶部插入。
            scrollController.beginPreservingPrepend()
            scrollController.endPreservingPrependAfterLayout()

        case .appended(let count):
            let appendedMessages = Array(viewModel.messages.suffix(count))
            if appendedMessages.contains(where: { $0.role == "user" }) {
                // 用户主动发送是明确的“回到当前对话”意图。
                pendingNewMessageCount = 0
                hasUnseenStreamingUpdate = false
                scrollController.scrollToBottom(animated: true)
            } else if scrollController.viewport.isNearBottom {
                scrollController.scrollToBottom(animated: false)
            } else {
                pendingNewMessageCount += count
            }

        case .replaced:
            if current.count == 0 {
                didInitialScrollToBottom = false
                pendingNewMessageCount = 0
                hasUnseenStreamingUpdate = false
            } else if !didInitialScrollToBottom {
                performInitialScrollIfNeeded()
            }
        }
    }

    private func handleViewportChange(_ viewport: ChatScrollViewportState) {
        if viewport.isNearBottom {
            pendingNewMessageCount = 0
            hasUnseenStreamingUpdate = false
        }

        let shouldLoad = historyLoadGate.shouldLoad(
            viewport: viewport,
            canLoad: didInitialScrollToBottom && viewModel.hasEarlierSessions,
            isLoading: viewModel.isLoadingEarlierSession
        )
        guard shouldLoad else { return }

        Task {
            await triggerLoadEarlier()
        }
    }

    private func triggerLoadEarlier() async {
        guard didInitialScrollToBottom,
              viewModel.hasEarlierSessions,
              !viewModel.isLoadingEarlierSession else { return }

        _ = await viewModel.loadEarlierSession()
    }

    // MARK: - Transaction Detail

    private func openTransactionDetail(_ message: ChatMessageViewData) {
        guard let transactionId = message.resolveLinkedEntityId(for: .finance) else { return }
        openTransactionDetail(transactionId)
    }

    /// 计划确认页落库：勾选优先结果→Goal、勾选行动卡→任务/习惯、拒绝→反馈
    private func confirmLifePlanSelection(_ selection: LifePlanReviewView.LifePlanConfirmSelection) {
        do {
            let token = try LifePlanRepository.shared.confirmPlan(
                planID: selection.planID,
                selectedPriorityIDs: selection.selectedPriorityIDs,
                selectedActionIDs: selection.selectedActionIDs,
                rejections: selection.rejections
            )
            GoalNotificationService.broadcastGoalDataChange()
            viewModel.finishLifePlanConfirm(
                planID: selection.planID,
                token: token,
                createdGoalTitle: nil,
                createdTaskCount: token.taskIDs.count,
                createdHabitCount: token.habitIDs.count
            )
        } catch {
            viewModel.lifePlanForReview = nil
            viewModel.showLifePlanReview = false
        }
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
            DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false))
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
        case .transaction(let txData):
            // 优先用被点击卡片自己的实体 ID；旧格式消息卡片无 ID 时退回消息级（单卡场景无歧义）
            let transactionId = txData.entityID
                .flatMap(UUID.init(uuidString:))
                ?? message.resolveLinkedEntityId(for: .finance)
            if let transactionId {
                let transaction = FinanceRepository.shared.findTransaction(by: transactionId)
                activeSheet = transaction.map { .editTransaction($0) }
            }
        case .task(let taskData):
            // 任务卡确认后 taskId 直接写在卡片数据里，优先于消息级缓存
            let taskId = taskData.taskId ?? message.resolveLinkedEntityId(for: .task)
            if let taskId {
                // HomeView 监听 deepLinkState 变化后自动切换 activeScreen。
                DeepLinkState.shared.navigate(to: .taskDetail(taskId: taskId))
            }
        case .anniversary(let anniversaryData):
            // 确认创建后纪念日 ID 回写在卡片数据里
            if let anniversaryId = anniversaryData.anniversaryId.flatMap(UUID.init(uuidString:))
                ?? message.resolveLinkedEntityId(for: .anniversary) {
                DeepLinkState.shared.navigate(to: .anniversaryDetail(anniversaryId: anniversaryId))
            }
        case .habitCheckIn, .mood, .weight:
            break
        case .analysisSummary, .analysisTrend, .analysisBreakdown, .analysisComparison, .analysisHighlights, .flexibleQuery, .goalChoice, .budget:
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
        case .voiceInput:
            VoiceInputSheet(speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .chat)) { transcript in
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
