//
//  ChatMessageListPane.swift
//  Holo
//
//  消息滚动列表：滚动桥 / 历史分页 / 时间戳分隔 / 消息卡 / 回底按钮。
//  状态仍归 ChatView 单点持有，此处经 Binding 读写；卡片交互回弹见 Actions。
//
//  2026-09-17 真机栈溢出二修拆出的结构体边界（原在 ChatView.swift）；
//  2026-10-23 移到独立文件（红线 §6 行数减负）：struct 边界与行为零变化，
//  仅 private → internal。禁止把本结构体内联回 ChatView 计算属性（红线 §3 陷阱 10）。
//

import SwiftUI

struct ChatMessageListPane: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var scrollController: ChatScrollController
    let internalLogAction: ((ChatMessageViewData) -> Void)?

    @Binding var didInitialScrollToBottom: Bool
    @Binding var historyLoadGate: ChatHistoryLoadGate
    @Binding var pendingNewMessageCount: Int
    @Binding var hasUnseenStreamingUpdate: Bool
    /// 深链定位请求：非 nil 时滚动到该消息（云端分析完成推送直达结果卡），消费后清空
    @Binding var pendingScrollTargetMessageID: UUID?

    /// 消息卡交互回弹：目标 @State 全在 ChatView（驱动 sheet / 全屏 cover / 侧栏），
    /// 闭包由 ChatView 构造时注入，保持单一数据源。
    struct Actions {
        let onIntentTagTap: (ChatMessageViewData) -> Void
        let onCardTap: (ChatMessageViewData, ChatCardData) -> Void
        let presentSheet: (ChatSheet) -> Void
        let onAgentDetail: (ChatMessageViewData) -> Void
        let onOpenTransaction: (UUID) -> Void
        let onOpenFlexibleQuery: (FlexibleQueryChatCardData) -> Void
        let onShowMembership: () -> Void
        let onPendingCardDelete: (PendingCardDelete) -> Void
        let onCategoryEditPrefill: (ChatMessageViewData, String, PendingTransactionPrefill) -> Void
        let onReport: (ChatMessageViewData) -> Void
        /// 待确认任务卡设置行编辑入口：弹层状态归 ChatView，经此回传（单一数据源）
        let onTaskEdit: (PendingTaskEdit) -> Void
    }

    let actions: Actions

    var body: some View {
        ScrollViewReader { proxy in
        GeometryReader { viewport in
        ScrollView(showsIndicators: false) {
            // 当前会话首批最多 50 条、历史每次只增 16 条。这里用确定高度的 VStack，
            // 避免 LazyVStack 在复杂卡片离屏后用估算高度占位，出现录屏中的大片空白和跳动。
            VStack(spacing: 12) {
                if viewModel.hasLoadedMessages
                    && (viewModel.hasEarlierSessions
                        || viewModel.isLoadingEarlierSession
                        || viewModel.earlierHistoryLoadFailed) {
                    historyLoadingHeader
                }

                ForEach(viewModel.messages, id: \.id) { message in
                    messageRow(for: message, proxy: proxy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            // 短对话贴近输入栏；长对话由 UIScrollView 的真实 contentSize 决定位置。
            // 不再使用 defaultScrollAnchor，避免它与手动 offset 同时重排内容。
            .frame(minHeight: viewport.size.height, alignment: .bottom)
            .background(alignment: .topLeading) {
                ChatScrollViewBridge(controller: scrollController)
                    .frame(width: 1, height: 1)
                ChatScrollIndicator()
                    .frame(width: 1, height: 1)
            }
        }
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
        .onChange(of: pendingScrollTargetMessageID) { _, _ in
            scrollToPendingTargetIfPossible(proxy: proxy)
        }
        .onChange(of: viewModel.hasLoadedMessages) { _, _ in
            // 冷启动兜底：深链先到、消息后加载完成时补定位
            scrollToPendingTargetIfPossible(proxy: proxy)
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
        }
    }

    // MARK: - Message Row

    /// 单条消息行（时间分隔条 + 消息气泡）。
    /// 从 body 原样拆出：ChatMessageListPane 的 body 表达式已在类型检查上限边缘，
    /// 往 ForEach 内联的巨型初始化里再加参数会触发 "unable to type-check in reasonable time"。
    @ViewBuilder
    private func messageRow(for message: ChatMessageViewData, proxy: ScrollViewProxy) -> some View {
        if message.showsTimestampSeparator {
            ChatTimeStampSeparator(date: message.timestamp)
        }

        MessageBubbleView(
            message: message,
            streamingText: viewModel.isStreaming && message.isStreaming ? viewModel.streamingText : nil,
            goalDraftForReview: viewModel.goalDraftForReview,
            latestGoalPlanningAssistantMessageID: viewModel.latestGoalPlanningAssistantMessageID,
            showsAIHeader: aiHeaderMessageIDs.contains(message.id),
            onIntentTagTap: { msg in
                actions.onIntentTagTap(msg)
            },
            onCardTap: { message, cardData in
                actions.onCardTap(message, cardData)
            },
            onFlexibleQueryTransactionTap: { transactionId in
                actions.onOpenTransaction(transactionId)
            },
            onFlexibleQueryViewAllTap: { queryData in
                actions.onOpenFlexibleQuery(queryData)
            },
            onViewLog: internalLogAction,
            onCompactAnalysisTap: {
                guard message.metadataState == .loaded,
                      message.analysisContext != nil else { return }
                actions.presentSheet(.analysisDetail(message))
            },
            onAgentDeepAnalysisTap: {
                guard message.agentResult != nil else { return }
                actions.onAgentDetail(message)
            },
            onAgentScopeChange: { preset in
                guard let result = message.agentResult else { return }
                Task { await viewModel.changeAnalysisScope(from: result, preset: preset) }
            },
            onAgentResumePaused: {
                viewModel.resumePausedAgentJobs(sourceMessageID: message.id)
            },
            onPeriodReplayExpansionChanged: { message, isExpanded in
                // 收起方向：内容变短可能让偏移越过新边界，交给底层 UIScrollView 校正。
                guard !isExpanded else {
                    // 展开方向：内容只增不减，偏移天然合法；把被点击卡片柔和带回可视区，
                    // 避免展开后的长内容把操作入口瞬间推离屏幕。
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(HoloAnimation.standard) {
                            proxy.scrollTo(message.id, anchor: .bottom)
                        }
                    }
                    return
                }
                scrollController.requestOffsetClamp()
            },
            onGoalDraftCardTap: {
                viewModel.showGoalDraftReview = true
            },
            onOpenMatter: { matterID in
                actions.presentSheet(.matterDetail(matterID))
            },
            onOpenTask: { taskID in
                actions.presentSheet(.taskDetail(taskID))
            },
            onSavedGoalCardTap: { goalId in
                DeepLinkState.shared.navigate(to: .goalDetail(goalId: goalId))
            },
            onRetry: {
                Task { await viewModel.retryMessage(message) }
            },
            onLearnPlus: {
                actions.onShowMembership()
            },
            onCardDelete: { msg, entityId, category, description in
                actions.onPendingCardDelete(PendingCardDelete(
                    category: category,
                    entityId: entityId,
                    description: description
                ))
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
            onTaskEditDueDate: { msg, taskData in
                actions.onTaskEdit(PendingTaskEdit(messageID: msg.id, itemID: taskData.itemID, kind: .dueDate))
            },
            onTaskEditReminders: { msg, taskData in
                actions.onTaskEdit(PendingTaskEdit(messageID: msg.id, itemID: taskData.itemID, kind: .reminders))
            },
            onTaskEditList: { msg, taskData in
                actions.onTaskEdit(PendingTaskEdit(messageID: msg.id, itemID: taskData.itemID, kind: .list))
            },
            onTaskEditContent: { msg, taskData in
                actions.onTaskEdit(PendingTaskEdit(messageID: msg.id, itemID: taskData.itemID, kind: .content))
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
                let prefill = PendingTransactionPrefill(
                    amount: renderData["amount"] ?? "0",
                    note: renderData["note"] ?? renderData["categoryCandidate"],
                    type: type,
                    category: nil,
                    date: TransactionDateResolver.resolve(from: renderData)
                )
                actions.onCategoryEditPrefill(msg, pending.id, prefill)
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
                actions.onReport(msg)
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
            },
            onPlanningRunCancel: { msg in
                viewModel.cancelPlanningRun(msg.id)
            }
        )
        .equatable()
        .id(message.id)
        .onAppear {
            viewModel.loadMetadataIfNeeded(for: message.id)
        }
    }

    // MARK: - AI 名头分组

    /// 当前消息列表中需要显示「Holo + AI」名头行的消息集合（各组组首）。
    /// 声明为计算属性而非 body 内局部 let：ChatMessageListPane 的 body 表达式已接近
    /// 类型检查上限，再往 ViewBuilder 里加语句会触发 "unable to type-check in reasonable time"。
    private var aiHeaderMessageIDs: Set<UUID> {
        Self.computeAIHeaderMessageIDs(in: viewModel.messages)
    }

    /// 计算需要显示「Holo + AI」名头行的消息集合（各组组首）：
    /// 连续 Holo 普通消息并入同组，仅组首显示名头行（iMessage/微信分组惯例）。
    /// 打断并重起分组的条件：上一条不是可并组的 Holo 消息（用户消息/独立类型卡），
    /// 或本条上方有时间分隔条、本条自身是独立类型卡。
    private static func computeAIHeaderMessageIDs(in messages: [ChatMessageViewData]) -> Set<UUID> {
        var ids = Set<UUID>()
        var previousContinuesGroup = false
        for message in messages {
            let isAI = message.role != "user"
            let standalone = isStandaloneCardMessage(message)
            if isAI && (!previousContinuesGroup || message.showsTimestampSeparator || standalone) {
                ids.insert(message.id)
            }
            previousContinuesGroup = isAI && !standalone
        }
        return ids
    }

    /// 独立类型卡消息：分析 / 回放 / 方案 / 额度等整卡形态自成视觉单元，
    /// 前后都不并入名头分组（其自身与下一条消息都会重起名头）。
    private static func isStandaloneCardMessage(_ message: ChatMessageViewData) -> Bool {
        message.messageType == .periodReplay
            || message.messageType == .quotaExhausted
            || message.messageType == .lifePlan
            || message.messageType == .contextPlan
            || message.messageType == .todayRelief
            || message.messageType == .goalPlanning
            || message.savedGoalCard != nil
            || message.isQueryAnalysis
            || !message.analysisCards.isEmpty
            || message.flexibleQueryCard != nil
    }

    // MARK: - IM Scroll Behavior

    /// 深链定位（云端分析完成推送直达结果卡）：目标消息已在列表中才滚动，消费后清空请求；
    /// 消息未加载（冷启动恢复中）时保留请求，等加载完成再定位。
    private func scrollToPendingTargetIfPossible(proxy: ScrollViewProxy) {
        guard let targetID = pendingScrollTargetMessageID,
              viewModel.messages.contains(where: { $0.id == targetID }) else { return }
        pendingScrollTargetMessageID = nil
        withAnimation(HoloAnimation.smooth) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    @ViewBuilder
    private var historyLoadingHeader: some View {
        Group {
            if viewModel.isLoadingEarlierSession {
                HStack(spacing: 7) {
                    ProgressView()
                        .scaleEffect(0.68)
                    Text("正在加载更早的消息")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
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
                .accessibilityLabel(String(localized: "加载更早的消息"))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .animation(HoloAnimation.enter, value: viewModel.isLoadingEarlierSession)
        .animation(HoloAnimation.enter, value: viewModel.earlierHistoryLoadFailed)
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
                    .foregroundColor(.holoToolText)
                    .frame(width: 36, height: 36)
            }
            // 视觉与热区同源：iOS26 下 plain 按钮热区收缩到文字，材质胶囊必须画在 label 内，
            // contentShape 也必须在 label 末尾（挂在 Button 外不扩展命中区）
            .padding(.leading, pendingLatestActivityCount > 0 ? 7 : 0)
            .padding(.trailing, pendingLatestActivityCount > 0 ? 2 : 0)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.holoToolTextSecondary.opacity(0.18), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityLabel(
            pendingLatestActivityCount > 0
                ? String(localized: "回到最新消息，\(pendingLatestActivityCount) 条新消息")
                : String(localized: "回到最新消息")
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
}