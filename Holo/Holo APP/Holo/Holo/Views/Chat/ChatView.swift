//
//  ChatView.swift
//  Holo
//
//  AI 对话主界面
//  消息列表 + 快捷栏 + 输入栏
//
//  🚨 红线文件：本文件有 1800 行硬上限，超线禁止改动（docs/standards/quality-redlines.md §6）。
//  本文件视图链过深曾在真机三次栈溢出闪退（0917 / 0923 / 1022，主线程栈仅 1MB；
//  模拟器 8MB 栈永远测不出，模拟器绿灯无证明力）。给本文件带来任何改动的构建，
//  交付前必须真机门禁 AICrashDeviceReproUITests 两用例跑绿。
//  行数由 HoloTests/ChatViewWeightGuardTests 自动把关，超线先拆存量再加新代码：
//  新界面块一律建独立 struct 文件；只拆叶子子件、禁止新增中间容器层；
//  大块构造拆独立 getter/方法帧（makeListActions / reportPane 是范本）。
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
    /// 深链要求滚动定位到的消息（云端分析完成推送点开 → 直达结果卡）；
    /// 由消息列表消费后清空
    @State private var pendingScrollTargetMessageID: UUID?
    @State private var pendingVoiceTranscriptToSend: String?
    @State private var pendingDelete: PendingCardDelete?
    @State private var showDeleteConfirmation = false
    /// 全屏 cover 单通道（弹层收敛 2026-10-23）：报告详情 / 回放阅读 / 财务证据搜索。
    /// 窄屏由此呈现 fullScreenCover；宽屏（≥860）由 activeSidePanel 读同一状态走右侧栏——
    /// 单一数据源双消费，替代原 agentDetailMessage / replayReaderMessage /
    /// financeSearchRoute 三个 @State + 三个 cover 修饰符。
    @State private var coverRoute: ChatCoverRoute?
    @State private var memoryInboxSnapshot: HoloMemoryInboxSnapshot?
    /// 键盘遮挡内容区的高度（已扣除底部 Home Indicator 安全区）。
    /// ZStack 平级常驻模式下祖先视图忽略了键盘安全区，系统自动避让失效，
    /// 因此这里手动监听键盘 frame 变化并给内容加 bottom padding。
    @State private var keyboardOverlap: CGFloat = 0
    @Binding var goalPlanningRequest: GoalPlanningRequest?
    /// 跨模块洞察直达（首页胶囊 / 系统通知）：消费 .memoryInsight 深链
    @ObservedObject private var deepLinkState = DeepLinkState.shared
    /// Matter「进行中的事」对话上下文（详情页进入 / 胶囊退出）
    @ObservedObject var matterChatStore = MatterChatContextStore.shared

    // MARK: 页内双 Tab（对话 / 报告）——设计文档 §4.1


    @State private var selectedPageTab: ChatPageTab = .chat
    /// 报告 pane 首次切换才构建（聊天页性能保护），之后常驻不销毁
    @State private var hasVisitedReportTab = false
    @StateObject private var reportViewModel = ChatReportTabViewModel()

    // MARK: 依据侧栏（2026-09-16 可用性改造方案 2B）
    // 宽屏（内容宽 ≥860）：报告详情 / 回放阅读按需在右侧栏打开，聊天消息与
    // 输入框保持可见，追问挂在侧栏内不影响左列；关闭侧栏恢复舒适聊天列。
    // 窄屏 / iPhone：维持原全屏 cover 语义（旋转跨档时同一份状态无缝迁移）。

    @Environment(\.holoContentWidth) private var chatContentWidth
    private var isWideLayout: Bool {
        HoloLayoutPolicy.isSplitReady(contentWidth: chatContentWidth)
    }

    private enum ChatSidePanel {
        case reportDetail(ChatMessageViewData)
        case replayReader(ChatMessageViewData)
    }

    /// 侧栏与全屏 cover 同读 coverRoute（单一数据源）：宽屏走侧栏，
    /// 窄屏走 cover 修饰符，旋转跨档同一状态无缝迁移（原语义保留）。
    private var activeSidePanel: ChatSidePanel? {
        guard isWideLayout else { return nil }
        switch coverRoute {
        case .reportDetail(let message):
            return .reportDetail(message)
        case .replayReader(let message):
            return .replayReader(message)
        case .financeSearch, nil:
            return nil
        }
    }

    /// 全屏 cover 门控绑定：宽屏详情走侧栏，cover 恒 nil 不弹（原方案 2B 语义）
    private var coverBinding: Binding<ChatCoverRoute?> {
        Binding(
            get: { isWideLayout ? nil : coverRoute },
            set: { coverRoute = $0 }
        )
    }

    /// 外部传入的预填文本（如从记忆长廊"继续问AI"跳转）
    var prefillText: String? = nil
    var opensVoiceInputOnAppear: Bool = false
    /// 外部入口「只聚焦不预填」信号（看板「对 Holo 说」/第一步行动卡），透传给输入栏；
    /// Binding 以便输入栏消费后归零，防 AI 页重建后重复触发
    var inputFocusTrigger: Binding<Int> = .constant(0)

    private var internalLogAction: ((ChatMessageViewData) -> Void)? {
        #if DEBUG || INTERNAL_DIAGNOSTICS
        // 闭包只捕获浅值 Binding（约 32 字节），不捕获 self——直接捕获会在
        // outlined init with copy of ChatView 里整份复制本 struct（2026-09-23
        // 语音按钮闪退 .ips 的最后一帧即此处，三修教训）
        let logBinding = $viewingLog
        return { message in
            logBinding.wrappedValue = HoloInternalLogService.shared.log(for: message.id)
        }
        #else
        return nil
        #endif
    }

    init(
        goalPlanningRequest: Binding<GoalPlanningRequest?> = .constant(nil),
        prefillText: String? = nil,
        opensVoiceInputOnAppear: Bool = false,
        inputFocusTrigger: Binding<Int> = .constant(0)
    ) {
        self._goalPlanningRequest = goalPlanningRequest
        self.prefillText = prefillText
        self.opensVoiceInputOnAppear = opensVoiceInputOnAppear
        self.inputFocusTrigger = inputFocusTrigger
    }

    var body: some View {
        ZStack {
            Color.holoToolBackground.ignoresSafeArea()

            // 宽屏（iPad）才包 HStack 侧栏层；iPhone/窄屏不付这一层容器级联——
            // 真机主线程仅 1MB 栈，容器层级与按值复制的视图体开销乘在每一层上
            // （2026-09-17 真机栈溢出二修，见文件尾结构体边界注释）
            if isWideLayout {
                HStack(spacing: 0) {
                    chatColumn

                    // 依据/报告侧栏（宽屏按需出现，方案 2B）
                    if let panel = activeSidePanel {
                        chatSidePanel(panel)
                    }
                }
            } else {
                chatColumn
            }
        }
        // 关闭系统自动键盘避让（祖先链在 ZStack 常驻模式下已忽略键盘安全区，
        // 系统避让本就到不了这里；统一由上面的 keyboardOverlap padding 手动控制，
        // 避免 sheet/NavigationStack 场景下系统避让与手动 padding 叠加）
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardOverlap(note)
        }
        #endif
        .swipeBackToDismiss(isResidentScreenRoot: true) {
            viewModel.clearContinuationDraft()
            close()
        }
        .animation(HoloAnimation.standard, value: memoryInboxSnapshot)
        .animation(HoloAnimation.standard, value: viewModel.memoryNotice)
        .sheet(item: $viewModel.goalWorkshopLaunch) { launch in
            GoalWorkshopFlowView(launch: launch)
        }
        // 弹层收敛（2026-10-23 第四次发作二修）：原 5 个散装 sheet（记忆确认队列 /
        // 会员中心 / 举报 / 改分类 / 任务卡编辑）并入 activeSheet 枚举单通道——
        // 每层 sheet 修饰符都是 body 主链上的 AG 节点（约 100KB 真机栈/层，红线 §6）
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            sheetContent(sheet)
        }
        // 「一个发现」阅读面板（01 §2）：打开期间不被新结果替换；撤权/失效由
        // refreshDiscoveryState 强制关闭并显示失效说明
        .sheet(isPresented: $viewModel.showsDiscoveryDetail) {
            DiscoveryDetailSheet(
                finding: viewModel.discoveryFinding,
                invalidationText: viewModel.discoveryInvalidationText,
                service: viewModel.discoveryService,
                onOpenSource: { sourceRef in
                    viewModel.openRecord(sourceRef: sourceRef)
                },
                onOpenSettings: {
                    viewModel.closeDiscoveryDetail()
                    activeSheet = .holoAIUserSettings
                },
                onStartConversation: { _ in
                    viewModel.closeDiscoveryDetail()
                },
                onDismiss: {
                    viewModel.closeDiscoveryDetail()
                }
            )
        }
        .task {
            await viewModel.setup()
            await viewModel.refreshDiscoveryState()
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
            consumeCloudReportDeepLink()
        }
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            consumeInsightDeepLink()
            consumeCloudReportDeepLink()
        }
        .onChange(of: prefillText) { _, newValue in
            // 常驻页兜底：本页常驻不销毁，外部入口（今日看板「开始一件事」、
            // 看板快捷记录等）在页面已存在时设置预填，.task 不会重跑，靠这里写入；
            // 输入框已有内容时不覆盖用户正在输入的文字
            guard let text = newValue, !text.isEmpty, viewModel.inputText.isEmpty else { return }
            viewModel.inputText = text
        }
        .onReceive(ChatReportTabRouter.shared.$requestTicket.dropFirst()) { _ in
            // dropFirst：@Published 订阅时会先回放当前值，不滤掉会把
            // 「进入页面」误判成一次跳转请求，导致默认落在报告 Tab。
            switchToReportTab()
        }
        .onChange(of: goalPlanningRequest) { _, request in
            guard let request else { return }
            viewModel.startGoalPlanning(seedText: request.seedText)
            goalPlanningRequest = nil
        }
        #if DEBUG || INTERNAL_DIAGNOSTICS
        #if canImport(UIKit)
        .fullScreenCover(isPresented: Binding(
            get: { viewingLog != nil },
            set: { if !$0 { viewingLog = nil } }
        )) {
            if let viewingLog {
                ChatLogView(log: viewingLog)
                    .holoContentColumn()
            }
        }
        #else
                .sheet(isPresented: Binding(
            get: { viewingLog != nil },
            set: { if !$0 { viewingLog = nil } }
        )) {
            if let viewingLog {
                ChatLogView(log: viewingLog)
                    .holoContentColumn()
            }
        }
        #endif
        #endif
        // 全屏 cover 单通道（弹层收敛 2026-10-23）：财务证据搜索 + 报告详情 +
        // 回放阅读原为三个独立 fullScreenCover 修饰符，收敛为单通道；宽屏下
        // 报告详情 / 回放走右侧栏（coverBinding 恒 nil 不弹，方案 2B 语义保留）
        #if canImport(UIKit)
        .fullScreenCover(item: coverBinding) { route in
            coverContent(route)
        }
        #else
                .sheet(item: coverBinding) { route in
            coverContent(route)
        }
        #endif
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
            Button("取消", role: .cancel) {}
            Button("去开启") {
                activeSheet = .aiConsent
            }
        } message: {
            Text(HoloAIDataProcessingConsent.requiredMessage)
        }
        .sheet(isPresented: $viewModel.showPeriodReplayPicker) {
            PeriodReplayPickerSheet { periodType, start, end in
                viewModel.showPeriodReplayPicker = false
                Task { await viewModel.startPeriodReplay(periodType: periodType, start: start, end: end) }
            }
        }
        // 云端分析首次启用前的隐私说明：确认后续跑挂起中的云端分析；
        // 未确认直接关闭则本次分析落「未开启」卡（云端独占，不回落本地）
        .sheet(isPresented: $viewModel.showCloudPrivacySheet, onDismiss: {
            viewModel.abandonPendingCloudAnalysis()
        }) {
            CloudAnalysisPrivacySheet {
                viewModel.confirmCloudPrivacyAndContinue()
            }
            .presentationDetents([.medium])
        }
        #if canImport(UIKit)
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
                .holoContentColumn()
            }
        }
        #else
                .sheet(isPresented: $viewModel.showGoalDraftReview) {
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
                .holoContentColumn()
            }
        }
        #endif
        #if canImport(UIKit)
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
                .holoContentColumn()
            }
        }
        #else
                .sheet(isPresented: $viewModel.showLifePlanReview) {
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
                .holoContentColumn()
            }
        }
        #endif
    }

    // MARK: - Navigation Bar

    /// 对话页主列：导航栏 + Matter 状态件 + 授权门/内容区。
    /// 子件全部为独立 struct（小体积引用进本列的结构类型），本列自身保持浅结构。
    /// ⚠️ 三修教训（2026-09-23 真机 .ips 两轮实锤）：本列与 pageTabContent 必须
    /// 保持内联——中间再包容器 struct（ChatMainColumn/ChatPageTabContainer 方案）
    /// 会让 AttributeGraph 多下钻两层（每层约 12 帧 × 8KB），入口链直接爆栈。
    /// struct 边界只用于给「叶子子件」封顶单帧，禁止用来给链路「加层」。
    private var chatColumn: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            // AI 设置入口（2026-10-23「一个发现」统一设置）：正式 HoloAI 用户页，Debug/Release 都可见；
            // 开发者 AI 调试页入口移入正式页的 Debug 区
            let onOpenSettings: () -> Void = {
                activeSheet = .holoAIUserSettings
            }
            ChatNavBar(
                onClose: {
                    viewModel.clearContinuationDraft()
                    close()
                },
                onOpenMemory: {
                    activeSheet = .memoryCenter
                },
                onOpenSettings: onOpenSettings
            )

            if !consent.isGranted {
                // 未开启 AI 数据处理授权：首屏给出准确引导，避免误导性的「服务不可用」
                ChatUnconfiguredView(isGranted: false, onOpenConsent: { activeSheet = .aiConsent })
            } else if viewModel.isConfigured || !viewModel.hasFinishedSetup || viewModel.didTimeoutLoadingConfig {
                // 已连接、正在检查中、或检查超时：都允许先进入对话页面，避免首屏卡死
                ChatPageTabBar(
                    selectedTab: $selectedPageTab,
                    showsReportDot: reportViewModel.hasUnreadReport,
                    onSelectReport: { switchToReportTab() },
                    onSelectChat: { reportViewModel.markHidden() }
                )
                ChatMemoryNoticeBar(
                    snapshot: memoryInboxSnapshot,
                    memoryNotice: viewModel.memoryNotice,
                    onTapPrimary: { handleMemoryNoticeTap() },
                    onTapDismiss: { dismissMemoryNotice() }
                )
                pageTabContent
            } else if !viewModel.isConfigured {
                // 服务不可用兜底
                ChatUnconfiguredView(isGranted: true, onOpenConsent: {})
            }
        }
        .padding(.bottom, keyboardOverlap)
    }

    /// 两 Tab 常驻不销毁（照搬记忆长廊 tabContent 模式）：
    /// 切走仅隐藏，聊天侧滚动位置与输入态跨切换存活。
    /// 报告 pane 延迟到首次切换才构建，避免加重聊天首帧。
    /// ⚠️ 禁止在 ZStack 外再包中间容器 struct（三修教训，见 chatColumn 注释）。
    /// 2026-10-23 三度发作随案：本闭包单帧曾内联 Actions 十一闭包构造 + 报告
    /// Tab 构造，帧序言 chkstk 探针直接触栈保护页（.ips 实锤）——大块构造必须
    /// 拆到独立 getter/方法帧（makeListActions / reportPane）：只拆帧、不加 View 层。
    private var pageTabContent: some View {
        ZStack {
            ChatContentColumn(
                viewModel: viewModel,
                scrollController: scrollController,
                initialPresentationStartedAt: initialPresentationStartedAt,
                isInitialConversationVisible: $isInitialConversationVisible,
                pendingNewMessageCount: $pendingNewMessageCount,
                hasUnseenStreamingUpdate: $hasUnseenStreamingUpdate,
                didInitialScrollToBottom: $didInitialScrollToBottom,
                historyLoadGate: $historyLoadGate,
                pendingScrollTargetMessageID: $pendingScrollTargetMessageID,
                inputFocusTrigger: inputFocusTrigger,
                internalLogAction: internalLogAction,
                onVoiceInputTap: { activeSheet = .voiceInput },
                actions: makeListActions()
            )
            .opacity(selectedPageTab == .chat ? 1 : 0)
            .allowsHitTesting(selectedPageTab == .chat)
            .accessibilityHidden(selectedPageTab != .chat)

            if hasVisitedReportTab {
                reportPane
            }
        }
    }

    /// 报告 Tab pane：从 pageTabContent 拆出的独立构造帧（if 保留原位，
    /// ZStack 内容类型与 View 层零变化）。常驻隐藏不销毁，切换只动可见性。
    @ViewBuilder
    private var reportPane: some View {
        ChatReportTabView(
            viewModel: reportViewModel,
            onOpenEntry: { entry in
                openReportEntry(entry)
            },
            onLaunchInChat: {
                // 空态橱窗 CTA：切回对话并打开场景面板——
                // 新用户第一发起就看到全部能力目录，比静默预填一句更有教育意义
                withAnimation(HoloAnimation.standard) {
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

    /// 消息卡交互回弹闭包集：从 pageTabContent 拆出的独立构造帧。
    /// Actions 是纯数据 struct（非 View），构造不加 View 层；十一个捕获
    /// self 的闭包复制发生在本方法帧内，不再撑大 ZStack 闭包帧。
    private func makeListActions() -> ChatMessageListPane.Actions {
        ChatMessageListPane.Actions(
            onIntentTagTap: { msg in handleIntentTagTap(msg) },
            onCardTap: { message, cardData in handleCardTap(message: message, cardData: cardData) },
            presentSheet: { activeSheet = $0 },
            onAgentDetail: { message in coverRoute = .reportDetail(message) },
            onOpenTransaction: { transactionId in openTransactionDetail(transactionId) },
            onOpenFlexibleQuery: { queryData in openFlexibleQueryResults(queryData) },
            onShowMembership: { activeSheet = .membershipCenter },
            onPendingCardDelete: { pendingDelete in
                self.pendingDelete = pendingDelete
                showDeleteConfirmation = true
            },
            onCategoryEditPrefill: { message, itemID, prefill in
                activeSheet = .categoryEdit(message: message, itemID: itemID, prefill: prefill)
            },
            onReport: { message in activeSheet = .reportMessage(message) },
            onTaskEdit: { edit in activeSheet = .taskEdit(edit) }
        )
    }

    /// 记忆提示条主点击：回执已读 + 有待确认走确认队列，否则直达长廊

    private func handleMemoryNoticeTap() {
        HoloMemoryReceiptStore.markWriteReceiptsRead()
        let hadPending = !HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled
            && (memoryInboxSnapshot?.pendingConfirmationCount ?? 0) > 0
        memoryInboxSnapshot = nil
        if hadPending {
            activeSheet = .memoryConfirmationQueue
        } else {
            DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: true))
        }
    }

    private func dismissMemoryNotice() {
        HoloMemoryReceiptStore.markWriteReceiptsRead()
        memoryInboxSnapshot = nil
    }


    // MARK: - Unconfigured View


    // MARK: - 页内双 Tab（对话 / 报告）

    /// 依据/报告侧栏（方案 2B）：定宽 520pt，左缘分隔线；顶部关闭后恢复全宽聊天列。
    /// 详情内容与窄屏全屏版同一套路由（追问能力、财务证据深链一致）。
    private func chatSidePanel(_ panel: ChatSidePanel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: HoloSpacing.md) {
                Text(sidePanelTitle(panel))
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    withAnimation(HoloAnimation.standard) {
                        closeSidePanel()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .holoHover()
                .accessibilityLabel(String(localized: "关闭"))
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)

            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.4))
                .frame(height: 0.5)

            switch panel {
            case .reportDetail(let message):
                ReportDetailRoute(
                    message: message,
                    chatViewModel: viewModel,
                    onFinanceDrilldown: { drilldown in
                        DeepLinkState.openFinanceEvidenceReview(drilldown)
                    }
                )
            case .replayReader(let message):
                ReportReplayReaderView(message: message)
            }
        }
        .frame(width: 520)
        .background(Color.holoToolBackground)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func sidePanelTitle(_ panel: ChatSidePanel) -> String {
        switch panel {
        case .reportDetail(let message):
            return message.agentResult?.title ?? String(localized: "报告详情")
        case .replayReader:
            return String(localized: "回放")
        }
    }

    private func closeSidePanel() {
        coverRoute = nil
    }

    private func switchToReportTab() {
        withAnimation(HoloAnimation.standard) {
            selectedPageTab = .report
        }
        hasVisitedReportTab = true
        reportViewModel.markSeen()
        Task { await reportViewModel.reload() }
        viewModel.showAnalysisScenarioPanel = false
        // 隐藏的聊天 pane 不会自动释放第一响应者，切走时手动收起键盘
#if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        #else
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSResponder.resignFirstResponder), with: nil
        )
        #endif
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

    /// 消费 .cloudAnalysisReport 深链（完成推送点开）：
    /// 回到聊天 Tab 并滚动定位到结果消息——此时多为「云端分析中」进度卡，
    /// 领取完成后原地变报告卡，用户无需任何操作。
    private func consumeCloudReportDeepLink() {
        guard case .cloudAnalysisReport(let messageID) = deepLinkState.pendingTarget else { return }
        deepLinkState.pendingTarget = nil
        selectedPageTab = .chat
        pendingScrollTargetMessageID = messageID
    }

    /// 档案行点击分流：深度分析 → 全屏报告详情；周期回放 → 全屏阅读版。
    private func openReportEntry(_ entry: ChatMessageRepository.ReportArchiveDTO) {
        guard let message = reportViewModel.loadReportMessage(id: entry.id) else { return }
        switch entry.kind {
        case .deepAnalysis:
            coverRoute = .reportDetail(message)
        case .periodReplay:
            coverRoute = .replayReader(message)
        }
    }

    // MARK: - Chat Content

    // MARK: - Message List


    // MARK: - IM Scroll Behavior

    // MARK: - Transaction Detail

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
            coverRoute = .financeSearch(route)
        } else {
            // HomeView 监听 deepLinkState 变化后会切换 activeScreen 到 .finance，
            // ChatView 会自动隐藏，无需手动 dismiss。
            DeepLinkState.shared.navigate(to: .finance)
        }
    }

    // MARK: - Keyboard Avoidance


    #if canImport(UIKit)
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
        let isKeyboardAppearing = overlap > keyboardOverlap + 1
        if isKeyboardAppearing {
            pendingNewMessageCount = 0
            hasUnseenStreamingUpdate = false
            // padding 改变会连续触发多帧 bounds/contentSize 更新；贴底窗口覆盖完整键盘动画。
            scrollController.scrollToBottom(
                animated: false,
                pinDuration: max(0.45, duration + 0.18)
            )
        }
        withAnimation(animation) {
            keyboardOverlap = overlap
        }
    }
    #endif

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
        case .holoAIUserSettings:
            HoloAIUserSettingsView(
                discoveryState: viewModel.discoveryService.settingsDetailState,
                discoveryService: viewModel.discoveryService
            )
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
        case .matterDetail(let matterID):
            // sheet 根视图需外部包栈：MatterDetailView 本体已去内嵌 NavigationStack
            NavigationStack {
                MatterDetailView(matterID: matterID) { discussID in
                    activeSheet = nil
                    matterChatStore.enter(matterID: discussID, source: .matterDetail)
                }
            }
        case .taskDetail(let taskID):
            Group {
                if let task = TodoRepository.shared.findTask(by: taskID) {
                    TaskDetailView(task: task, repository: TodoRepository.shared) {
                        activeSheet = nil
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.title).foregroundStyle(.tertiary)
                        Text(String(localized: "这条任务已被删除"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(30)
                }
            }
        case .voiceInput:
            VoiceInputSheet(speechProvider: SpeechRecognitionProviderFactory.makeConfiguredProvider(source: .chat)) { transcript in
                pendingVoiceTranscriptToSend = transcript
                activeSheet = nil
            }
        case .memoryCenter:
            NavigationStack {
                HoloMemoryCenterView()
            }
        case .memoryConfirmationQueue:
            MemoryConfirmationQueueView()
        case .membershipCenter:
            NavigationStack {
                HoloMembershipCenterView()
            }
        case .reportMessage(let message):
            ContentReportSheet(message: message)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .categoryEdit(let message, let itemID, let prefill):
            AddTransactionSheet(
                editingTransaction: nil,
                pendingPrefill: prefill
            ) { savedTransaction in
                viewModel.dismissPendingCardAfterEdit(
                    from: message,
                    itemID: itemID,
                    createdTransaction: savedTransaction
                )
                // item 关闭时状态整体释放（原三状态清空语义）
                activeSheet = nil
            }
        case .taskEdit(let edit):
            ChatTaskEditSheet(viewModel: viewModel, edit: edit)
        }
    }

    /// 全屏 cover 单通道内容（弹层收敛 2026-10-23）：三路由原样迁入，
    /// 呈现修饰与深链行为零变化。
    @ViewBuilder
    private func coverContent(_ route: ChatCoverRoute) -> some View {
        switch route {
        case .financeSearch(let route):
            FinanceSearchView(
                initialSearchText: route.keyword,
                exactTransactionIDs: route.transactionIDs
            )
            .holoContentColumn()
        case .reportDetail(let message):
            // 详情内可直接追问（不弹回对话页），追问出的新报告挂进追问记录；
            // 财务钻取深链经 HomeView 切换 activeScreen（设计文档 §4.3）
            ReportDetailRoute(
                message: message,
                chatViewModel: viewModel,
                onFinanceDrilldown: { drilldown in
                    DeepLinkState.openFinanceEvidenceReview(drilldown)
                }
            )
            .holoContentColumn()
        case .replayReader(let message):
            ReportReplayReaderView(message: message)
                .holoContentColumn()
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
        memoryInboxSnapshot = snapshot
    }
}

// MARK: - 聊天内容列 / 消息列表（结构体边界）
//
// 历史包袱：ChatView 曾把「消息滚动列表 + 空态 + 能力条 + 输入栏」整棵内联在
// body 的计算属性里。SwiftUI 的计算属性不构成类型边界，整棵树的结构类型会
// 全部摊进 ChatView.Body——嵌套数十层、编译器内部类型描述达数 KB。2026-09-17
// 实锤（真机 .ips）：进入 AI 页时 SwiftUI 元数据实例化 + AttributeGraph 逐层
// 下钻的递归深度超出主线程栈上限，栈溢出闪退（SIGSEGV，4 份日志同签名）。
// 拆成独立结构体后，父视图类型只引用类型名，深度到此封顶；消息列表再由
// ChatMessageListPane 二次封顶。禁止把这批结构体内联回计算属性。

/// 对话内容列：连接横幅 + 消息区（空态/列表）+ 能力条 + 场景面板 + 输入栏
private struct ChatContentColumn: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var scrollController: ChatScrollController
    let initialPresentationStartedAt: Date

    @Binding var isInitialConversationVisible: Bool
    @Binding var pendingNewMessageCount: Int
    @Binding var hasUnseenStreamingUpdate: Bool
    @Binding var didInitialScrollToBottom: Bool
    @Binding var historyLoadGate: ChatHistoryLoadGate
    @Binding var pendingScrollTargetMessageID: UUID?

    let inputFocusTrigger: Binding<Int>
    let internalLogAction: ((ChatMessageViewData) -> Void)?
    let onVoiceInputTap: () -> Void
    let actions: ChatMessageListPane.Actions

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.hasFinishedSetup {
                statusBanner(String(localized: "正在连接 Holo AI 服务，你现在也可以直接发送消息"))
            } else if viewModel.didTimeoutLoadingConfig {
                statusBanner(String(localized: "AI 服务连接较慢，已先放开聊天交互"))
            }

            // 消息列表 / 空状态卡片：仅在历史消息加载完成后才显示空状态，
            // 避免进入时「先显示空状态再突然消失」的闪烁。
            Group {
                if viewModel.isTrulyEmptyConversation {
                    ChatEmptyStateView(viewModel: viewModel)
                        .transition(.opacity)
                } else {
                    ChatMessageListPane(
                        viewModel: viewModel,
                        scrollController: scrollController,
                        internalLogAction: internalLogAction,
                        didInitialScrollToBottom: $didInitialScrollToBottom,
                        historyLoadGate: $historyLoadGate,
                        pendingNewMessageCount: $pendingNewMessageCount,
                        hasUnseenStreamingUpdate: $hasUnseenStreamingUpdate,
                        pendingScrollTargetMessageID: $pendingScrollTargetMessageID,
                        actions: actions
                    )
                }
            }
            // opacity 不参与布局：消息和复杂卡片会在不可见状态完成首轮测量，
            // reveal 时只切换可见性，不再触发第二次位移。
            .opacity(isInitialConversationVisible ? 1 : 0)
            .allowsHitTesting(isInitialConversationVisible)
            .accessibilityHidden(!isInitialConversationVisible)

            // 目标规划收集期常驻横幅：此期间普通输入会被规划会话消费，
            // 必须可见可退，不能让用户无感地「发了没反应」（2026-09-19 事故）
            if viewModel.isGoalPlanningCollecting {
                GoalPlanningActiveBanner { viewModel.cancelGoalPlanning() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            // Matter 上下文五件套（2026-09-23 统一交互：与目标规划横幅同区，
            // 全部会话态提示收敛在输入框上方；实现拆 ChatMatterStatusStack）
            ChatMatterStatusStack()

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
                    .foregroundColor(.holoToolText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.holoToolAI.opacity(0.2)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            // 场景预填来源提示：场景绑定随预填建立，改写问句仍按该场景分析；
            // 清空输入框或发送后自动消失（见 VM 计算属性）
            if let scenarioTitle = viewModel.activeScenarioPrefillTitle {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("将按「\(scenarioTitle)」场景分析 · 可改写问句，确认后发送")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.holoToolAI.opacity(0.95))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.holoToolAI.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.holoToolAI.opacity(0.22), lineWidth: 0.8))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .transition(.opacity)
            }

            // 输入栏
            ChatInputView(
                viewModel: viewModel,
                onInputActivated: {
                    returnToLatestForInput()
                },
                onVoiceInputTap: {
                    onVoiceInputTap()
                },
                onImagePicked: { data in
                    // 截图识别记账：附言取当前输入框文字（方案 §3.2 随图文字优先）
                    let caption = viewModel.inputText
                    viewModel.inputText = ""
                    Task { await viewModel.sendVisionMessage(rawImageData: data, caption: caption) }
                },
                onImagePickFailed: { message in
                    viewModel.errorMessage = message
                },
                inputFocusTrigger: inputFocusTrigger
            )
        }
        .animation(HoloAnimation.standard, value: viewModel.isTrulyEmptyConversation)
        .animation(HoloAnimation.standard, value: viewModel.streamingStatusHint)
        .animation(HoloAnimation.standard, value: viewModel.isGoalPlanningCollecting)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.showAnalysisScenarioPanel)
        .animation(HoloAnimation.standard, value: viewModel.activeScenarioPrefillTitle)
        .onChange(of: viewModel.showAnalysisScenarioPanel) { _, isOpen in
            // 面板展开时收起键盘，保证场景目录完整可见
            if isOpen {
#if canImport(UIKit)
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
                #else
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSResponder.resignFirstResponder), with: nil
                )
                #endif
                // 展开即刷新额度快照：用户此刻正在读「今日剩余」，不能拿启动时的旧值
                Task { await HoloSubscriptionService.shared.refreshStatus() }
            }
        }
        .task(id: viewModel.hasLoadedMessages) {
            await revealInitialConversationIfReady()
        }
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoToolSurface)
    }

    /// 目标规划收集期横幅：明示「输入会被规划消费」并提供唯一可靠的退出出口
    /// （此前退出入口只在草案生成后可达，收集期用户无感被劫，深度分析等显式意图失效）
    private struct GoalPlanningActiveBanner: View {
        let onExit: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.system(size: 12, weight: .semibold))
                Text("目标规划进行中 · 你的回复将用于生成目标草案")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onExit) {
                    Text("退出")
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Color.holoPrimary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "退出目标规划"))
            }
            .foregroundColor(.holoPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Color.holoPrimary.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.25), lineWidth: 0.8))
        }
    }

    /// 与成熟 IM 一致：点击输入区即表示继续最新对话。长距离直接到达，短距离柔和过渡；
    /// 后续键盘 frame 变化会继续延长贴底窗口，不会停在半途。
    private func returnToLatestForInput() {
        pendingNewMessageCount = 0
        hasUnseenStreamingUpdate = false
        scrollController.scrollToBottom(animated: true, pinDuration: 0.6)
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
}

// MARK: - 对话页结构件（2026-09-17 真机栈溢出二修）
//
// 除 ChatContentColumn / ChatMessageListPane 两道内容边界外，导航栏、页签条、
// 记忆提示条、授权引导页与 Matter 状态件也全部独立成 struct：计算属性会把整棵
// 子树的结构类型与按值体积摊进调用方（SwiftUI 每层容器帧都会复制一份），
// 只有 struct 才是体积边界。禁止把这批结构体内联回计算属性。

/// 页内双 Tab（对话 / 报告）——设计文档 §4.1
private enum ChatPageTab {
    case chat
    case report
}

/// 顶部导航栏：关闭 / 标题 / 设置入口（DEBUG）
private struct ChatNavBar: View {
    let onClose: () -> Void
    let onOpenMemory: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoToolTextSecondary.opacity(0.1))
                    .cornerRadius(16)
            }

            Spacer()

            Text("HOLO AI")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoToolText)

            Spacer()

            // 2026-10-25 M08：聊天页「记忆」入口（方案 §3.1；文字按钮+44pt 热区，
            // 大字体拥挤时设置齿轮保持本行，记忆入口不移除以保证可发现性）
            Button(action: onOpenMemory) {
                Text("记忆")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolAction)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("记忆"))
            .accessibilityIdentifier("chat.nav.memoryCenter")

            // 2026-10-23「一个发现」统一设置：正式 HoloAI 用户页入口，Debug/Release 都可见
            //（01 §4 正式入口一；开发者 AI 调试入口已移入该页 Debug 区）
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoToolTextSecondary.opacity(0.1))
                    .cornerRadius(16)
            }
            .accessibilityIdentifier("chat.nav.aiSettings")
            .accessibilityLabel(Text("HoloAI 设置"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.holoToolBackground)
        .zIndex(1)
    }
}

/// 未授权 / 服务不可用引导页
private struct ChatUnconfiguredView: View {
    /// true=已授权但服务不可用（只提示）；false=未授权（给开启入口）
    let isGranted: Bool
    let onOpenConsent: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isGranted ? "bubble.left.and.bubble.right.fill" : "lock.shield.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoPrimary)

            Text("HOLO AI 对话")
                .holoText(.pageTitle)
                .foregroundColor(.holoToolText)

            if isGranted {
                // 已授权但服务不可用：保留网络提示
                Text("AI 服务暂时不可用\n请稍后重试或检查网络连接")
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            } else {
                // 未授权：说明真实原因并提供开启入口
                Text("你还未开启 AI 数据处理授权\n开启后即可使用")
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)

                Button(action: onOpenConsent) {
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
}

/// 页内双 Tab（对话 / 报告）
private struct ChatPageTabBar: View {
    @Binding var selectedTab: ChatPageTab
    let showsReportDot: Bool
    /// 切到报告页（含已读标记与首次构建惰性初始化，由 ChatView 统筹）
    let onSelectReport: () -> Void
    /// 切回对话页后隐藏报告未读态
    let onSelectChat: () -> Void

    /// 选中白胶囊在两段间平滑滑动
    @Namespace private var pageTabNamespace

    var body: some View {
        HStack(spacing: 0) {
            pageTabButton(.chat, title: String(localized: "对话"), showsDot: false)
            pageTabButton(.report, title: String(localized: "报告"), showsDot: showsReportDot)
        }
        .frame(width: 190)
        .padding(3)
        .background(Color.holoToolTextSecondary.opacity(0.09), in: Capsule())
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func pageTabButton(_ tab: ChatPageTab, title: String, showsDot: Bool) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            if tab == .report {
                withAnimation(HoloAnimation.standard) {
                    onSelectReport()
                }
            } else {
                withAnimation(HoloAnimation.standard) {
                    selectedTab = .chat
                }
                onSelectChat()
            }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule().fill(Color.holoToolSurface)
                            .matchedGeometryEffect(id: "chatPageTabCapsule", in: pageTabNamespace)
                    }
                }
                .overlay {
                    // 深色下选中胶囊贴轨道底色：细描边兜出选中边界
                    if isSelected {
                        Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
                    }
                }
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
}

/// 记忆收件箱/使用回执提示条：占位于 Tab 栏与内容区之间，随内容排版不遮挡消息。
/// 收件箱下线后只在首次形成有效记忆时出现一次（首启说明），点击直达长廊；
/// 回滚口径（开关关闭）恢复「有待确认先弹确认队列」的旧动线——口径与动作在 ChatView。
private struct ChatMemoryNoticeBar: View {
    let snapshot: HoloMemoryInboxSnapshot?
    let memoryNotice: String?
    let onTapPrimary: () -> Void
    let onTapDismiss: () -> Void

    var body: some View {
        if let snapshot {
            HStack(spacing: HoloSpacing.xs) {
                Button(action: onTapPrimary) {
                    Label(snapshot.presentationText, systemImage: "brain.head.profile.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoToolText)
                }
                .buttonStyle(.plain)

                Button(action: onTapDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if let notice = memoryNotice {
            Label(notice, systemImage: "brain.head.profile.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoToolText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.2)))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - 待确认任务卡编辑会话
// PendingTaskEdit 与弹层路由 ChatTaskEditSheet 已拆 ChatTaskEditSheets.swift
// （2026-09-23 栈溢出三修）。
