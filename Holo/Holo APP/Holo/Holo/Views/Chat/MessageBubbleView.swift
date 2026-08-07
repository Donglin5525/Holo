//
//  MessageBubbleView.swift
//  Holo
//
//  消息气泡视图
//  区分用户/AI 消息样式
//

import SwiftUI

struct MessageBubbleView: View {
    #if DEBUG || INTERNAL_DIAGNOSTICS
    @ObservedObject private var internalAccess = HoloInternalAccessService.shared
    @ObservedObject private var internalLogs = HoloInternalLogService.shared
    #endif

    /// 订阅收藏状态：收藏态存在外部单例 ChatMessageStarStore（不在 message 里），
    /// 若不订阅，收藏/取消后 Equatable 判等会跳过 body 重算，菜单文案不切换。
    @ObservedObject private var starStore = ChatMessageStarStore.shared

    let message: ChatMessageViewData
    let streamingText: String?
    let goalDraftForReview: GoalDraft?
    var onIntentTagTap: ((ChatMessageViewData) -> Void)? = nil
    var onCardTap: ((ChatMessageViewData, ChatCardData) -> Void)? = nil
    var onFlexibleQueryTransactionTap: ((UUID) -> Void)? = nil
    var onFlexibleQueryViewAllTap: ((FlexibleQueryChatCardData) -> Void)? = nil
    var onViewLog: ((ChatMessageViewData) -> Void)? = nil
    var onCompactAnalysisTap: (() -> Void)? = nil
    var onAgentDeepAnalysisTap: (() -> Void)? = nil
    /// P1-12：Agent 分析失败后的重试入口
    var onAgentDeepAnalysisRetry: (() -> Void)? = nil
    var onPeriodReplayExpansionChanged: ((ChatMessageViewData, Bool) -> Void)? = nil
    var onGoalDraftCardTap: (() -> Void)? = nil
    var onSavedGoalCardTap: ((UUID) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    /// 额度耗尽卡片「了解 Holo Plus」点击，由上层导航到会员中心
    var onLearnPlus: (() -> Void)? = nil
    var onCardDelete: ((ChatMessageViewData, EntityCategory, String) -> Void)? = nil
    var onTaskConfirm: ((ChatMessageViewData) -> Void)? = nil
    var onTransactionConfirm: ((ChatMessageViewData) -> Void)? = nil
    var onTransactionCancel: ((ChatMessageViewData) -> Void)? = nil
    var onTransactionModifyCategory: ((ChatMessageViewData) -> Void)? = nil
    var onCopy: ((ChatMessageViewData) -> Void)? = nil
    var onEdit: ((ChatMessageViewData) -> Void)? = nil
    var onRegenerate: ((ChatMessageViewData) -> Void)? = nil
    /// P1-11：收藏/取消收藏
    var onToggleStar: ((ChatMessageViewData) -> Void)? = nil
    /// 分享消息文本（系统分享面板）
    var onShare: ((ChatMessageViewData) -> Void)? = nil
    /// 分享卡片截图（系统分享面板）
    var onShareCard: ((ChatMessageViewData) -> Void)? = nil

    private var displayText: String {
        streamingText ?? message.content
    }

    /// 可复制：非流式中的文本消息（卡片消息有自己的操作入口，不在此复制）
    private var canCopy: Bool {
        guard !message.isStreaming else { return false }
        // 卡片/分析/额度消息不复制（它们有结构化展示，复制文本意义不大）
        if !isUser, message.isQuotaExhausted { return false }
        if !isUser, message.isQueryAnalysis { return false }
        if !executionCards.isEmpty || cardData != nil { return false }
        if !message.analysisCards.isEmpty { return false }
        return !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 可编辑：仅普通用户消息（非 goalPlanning/periodReplay 等会话状态机消息）
    private var canEdit: Bool {
        isUser && !message.isStreaming && message.messageType == .normal
    }

    /// 可重新生成：AI 文本消息（非卡片、非分析、非额度），有父消息可重发
    private var canRegenerate: Bool {
        guard !isUser, !message.isStreaming else { return false }
        guard message.parentMessageId != nil else { return false }
        if message.isQuotaExhausted || message.isQueryAnalysis { return false }
        if !executionCards.isEmpty || cardData != nil { return false }
        if !message.analysisCards.isEmpty { return false }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// P1-11：可收藏（AI 消息均可，含卡片/分析——收藏的是「这条消息整体」而非数据结构）
    private var canStar: Bool {
        guard !isUser, !message.isStreaming else { return false }
        guard message.parentMessageId != nil else { return false }
        // 额度耗尽提示不收藏（它是提示卡片不是内容）
        guard !message.isQuotaExhausted else { return false }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || message.agentResult != nil
            || !executionCards.isEmpty
            || cardData != nil
    }

    /// 可分享：与复制同条件（有文字内容的非流式消息，用户/AI 都行）
    private var canShare: Bool { canCopy }

    /// 当前是否已收藏
    private var isStarred: Bool {
        ChatMessageStarStore.shared.isStarred(message.id)
    }

    /// 是否为目标计划草稿就绪消息（需要渲染为卡片而非气泡）
    private var isGoalDraftReady: Bool {
        !isUser
            && message.messageType == .goalPlanning
            && !message.isStreaming
            && goalDraftForReview != nil
    }

    private var isUser: Bool {
        message.role == "user"
    }

    /// 保存完成的目标消息（需要渲染成可跳转卡片）
    private var savedGoalCardData: GoalSavedChatCardData? {
        guard !isUser,
              message.messageType == .goalPlanning,
              !message.isStreaming else {
            return nil
        }
        return GoalSavedChatCardData(dictionary: message.extractedDataDictionary)
    }

    /// 是否可渲染为卡片（旧路径，单卡片兼容）
    private var cardData: ChatCardData? {
        guard !isUser,
              let intentStr = message.intent,
              let intent = AIIntent(rawValue: intentStr),
              !message.isStreaming else {
            return nil
        }
        return ChatCardData.from(intent: intent, data: message.extractedDataDictionary)
    }

    /// 从 executionBatch 构建多卡片数据
    private var executionCards: [ChatCardData] {
        ChatCardData.multiple(from: message.executionBatch)
    }

    var body: some View {
        Group {
            if isUser {
                // 用户消息：长按菜单（复制/编辑/分享），无三个点
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 60)
                    messageContent
                    userAvatar
                }
                .contextMenu { textMessageMenu }
            } else if isCardMessage {
                // AI 卡片消息：卡片右上角叠三个点（收藏/分享/删除），独立控件不与卡片点击冲突
                VStack(alignment: .leading, spacing: 10) {
                    aiHeader
                    ZStack(alignment: .topTrailing) {
                        messageContent
                        if cardMenuHasAction {
                            cardActionsMenu
                                .padding(.top, 6)
                                .padding(.trailing, 6)
                                .zIndex(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // AI 文字消息：长按菜单（复制/重新生成/收藏/分享）
                VStack(alignment: .leading, spacing: 10) {
                    aiHeader
                    messageContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { textMessageMenu }
            }
        }
    }

    // MARK: - 是否卡片消息

    /// 是否为 AI 卡片消息（用于决定用三个点菜单还是长按菜单）。
    /// 额度耗尽不算（它是提示卡片不是内容）。
    private var isCardMessage: Bool {
        guard !isUser, !message.isQuotaExhausted else { return false }
        return message.isQueryAnalysis
            || !executionCards.isEmpty
            || cardData != nil
            || !message.analysisCards.isEmpty
            || message.messageType == .periodReplay
            || savedGoalCardData != nil
            || isGoalDraftReady
    }

    // MARK: - 卡片右上角三个点菜单

    /// 卡片三个点是否需要显示（至少一个可用操作）
    private var cardMenuHasAction: Bool {
        if canStar { return true }
        if canShareCard { return true }
        if firstDeletableCard != nil { return true }
        #if DEBUG || INTERNAL_DIAGNOSTICS
        if internalAccess.canViewAILogs, internalLogs.hasLog(for: message.id) { return true }
        #endif
        return false
    }

    /// 卡片可分享：非流式的卡片消息均可截图分享。
    /// Goal 类卡片暂不支持分享（截图重建依赖外部数据，且私人目标分享价值低）。
    private var canShareCard: Bool {
        guard !message.isStreaming else { return false }
        if savedGoalCardData != nil { return false }
        if isGoalDraftReady { return false }
        return true
    }

    /// 卡片三个点菜单
    @ViewBuilder
    private var cardActionsMenu: some View {
        Menu {
            // 收藏/取消收藏
            if canStar {
                Button {
                    onToggleStar?(message)
                } label: {
                    Label(isStarred ? "取消收藏" : "收藏",
                          systemImage: isStarred ? "star.fill" : "star")
                }
            }
            // 分享（卡片截图）
            if canShareCard {
                Button {
                    onShareCard?(message)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            // 删除记录（仅有关联实体且未删除的卡片消息）
            if let info = firstDeletableCard {
                Button(role: .destructive) {
                    onCardDelete?(message, info.category, info.description)
                } label: {
                    Label("删除记录", systemImage: "trash")
                }
            }
            #if DEBUG || INTERNAL_DIAGNOSTICS
            if internalAccess.canViewAILogs, internalLogs.hasLog(for: message.id) {
                Button {
                    onViewLog?(message)
                } label: {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                }
            }
            #endif
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 26, height: 26)
                .background(Color.holoCardBackground.opacity(0.9))
                .clipShape(Circle())
                .contentShape(Circle())
        }
    }

    // MARK: - 文字消息长按菜单

    /// 文字消息长按菜单内容（复制/编辑/重新生成/收藏/分享/查看日志）
    @ViewBuilder
    private var textMessageMenu: some View {
        // 复制：对用户/AI 文本消息都可用（流式中、卡片消息、额度卡片除外）
        if canCopy {
            Button {
                onCopy?(message)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        // 编辑后重发：仅普通用户消息
        if canEdit {
            Button {
                onEdit?(message)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        // 重新生成：仅 AI 文本消息（非卡片、非分析、非额度、非流式中）
        if canRegenerate {
            Button {
                onRegenerate?(message)
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
        }
        // 收藏/取消收藏（AI 文字消息）
        if canStar {
            Button {
                onToggleStar?(message)
            } label: {
                Label(isStarred ? "取消收藏" : "收藏",
                      systemImage: isStarred ? "star.fill" : "star")
            }
        }
        // 分享：与复制同条件（有文字内容的非流式消息）
        if canShare {
            Button {
                onShare?(message)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        #if DEBUG || INTERNAL_DIAGNOSTICS
        // 完整日志仅在内部构建中开放，并继续校验后端身份，不属于 Plus 权益。
        if !isUser,
           internalAccess.canViewAILogs,
           internalLogs.hasLog(for: message.id) {
            Button {
                onViewLog?(message)
            } label: {
                Label("查看日志", systemImage: "doc.text.magnifyingglass")
            }
        }
        #endif
    }

    @ViewBuilder
    private var messageContent: some View {
        let analysisCardsData = message.analysisCards
        let hasAnalysisCards = !analysisCardsData.isEmpty
        let cards = executionCards
        let hasCards = !cards.isEmpty
        let singleCard = cardData
        let flexibleQueryCard = message.flexibleQueryCard

        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            // 渲染优先级：额度耗尽提示 > 已保存目标卡片 > 目标计划卡片 > 周期回放 > 分析卡片 > 批处理卡片 > 单卡片 > 通用文字。
            if message.isQuotaExhausted {
                QuotaExhaustedChatCard(message: message.content, onLearnPlus: onLearnPlus)
            } else if let savedGoalCardData {
                GoalSavedChatCard(data: savedGoalCardData) {
                    onSavedGoalCardTap?(savedGoalCardData.goalId)
                }
            } else if isGoalDraftReady {
                if let draft = goalDraftForReview {
                    GoalDraftReadyChatCard(draft: draft) {
                        onGoalDraftCardTap?()
                    }
                }
            } else if message.messageType == .periodReplay {
                if message.insightResult != nil || message.isStreaming || message.periodReplayJob != nil {
                    PeriodReplayChatCard(message: message) { isExpanded in
                        onPeriodReplayExpansionChanged?(message, isExpanded)
                    }
                } else {
                    bubbleContent
                }
            } else if message.isQueryAnalysis {
                if message.agentResult != nil || (message.isStreaming && message.analysisContext == nil) {
                    AgentDeepAnalysisCard(message: message) {
                        onAgentDeepAnalysisTap?()
                    } onRetry: {
                        onAgentDeepAnalysisRetry?()
                    }
                } else if message.analysisContext != nil {
                    AnalysisCompactChatCard(message: message) {
                        onCompactAnalysisTap?()
                    }
                } else {
                    bubbleContent
                }
            } else if hasAnalysisCards {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(analysisCardsData.enumerated()), id: \.offset) { _, card in
                        cardView(for: card)
                    }
                    if !displayText.isEmpty {
                        bubbleContent
                    }
                }
            } else if let flexibleQueryCard {
                VStack(alignment: .leading, spacing: 12) {
                    cardView(for: flexibleQueryCard)
                    if !displayText.isEmpty {
                        bubbleContent
                    }
                }
            } else if hasCards {
                if cards.count > 1 {
                    multiCardView(cards: cards)
                } else {
                    cardView(for: cards[0])
                }
            } else if let card = singleCard {
                cardView(for: card)
            } else {
                bubbleContent
            }

            // 意图标签只服务于可跳转结果；普通对话和未知意图不增加视觉噪声。
            if let intent = message.intent,
               let intentValue = AIIntent(rawValue: intent),
               intentValue != .unknown,
               !isUser,
               !hasCards,
               singleCard == nil,
               flexibleQueryCard == nil,
               !hasAnalysisCards,
               !message.isQueryAnalysis {
                intentTag(intent)
            }
        }
        .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Avatars

    /// 获取第一个可删除的卡片信息（用于上下文菜单）
    private var firstDeletableCard: (category: EntityCategory, description: String)? {
        let allCards = executionCards.isEmpty ? (cardData.map { [$0] } ?? []) : executionCards

        for card in allCards {
            switch card {
            case .transaction(let data):
                if message.hasLinkedEntity(for: .finance) && !message.isEntityDeleted(for: .finance) {
                    let desc = "\(data.displayTitle) ¥\(data.amount)"
                    return (.finance, desc)
                }
            case .task(let data):
                if message.hasLinkedEntity(for: .task) && !message.isEntityDeleted(for: .task) {
                    return (.task, "任务「\(data.title)」")
                }
            default:
                break
            }
        }
        return nil
    }

    private var aiAvatar: some View {
        Circle()
            .fill(Color.holoPrimary.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(.holoPrimary)
            }
    }

    private var aiHeader: some View {
        HStack(spacing: 9) {
            aiAvatar

            Text("Holo")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.holoTextPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Holo")
    }

    private var userAvatar: some View {
        Circle()
            .fill(Color.holoTextSecondary.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.holoTextSecondary)
            }
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            StreamingTextView(
                text: displayText,
                isStreaming: message.isStreaming && streamingText != nil
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.holoDivider.opacity(0.5))
            .clipShape(BubbleShape(isUser: true))
        } else {
            AIReadableResponseView(
                text: displayText,
                isStreaming: message.isStreaming && streamingText != nil,
                isError: message.isError,
                isRetryableStopped: message.isRetryableStopped,
                onRetry: onRetry
            )
        }
    }

    // MARK: - Card View

    /// 多卡片渲染（带汇总标题）
    @ViewBuilder
    private func multiCardView(cards: [ChatCardData]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.holoSuccess)
                Text("已为你处理 \(cards.count) 件事")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                cardView(for: card)
            }
        }
    }

    /// 根据卡片数据渲染对应领域的卡片视图
    @ViewBuilder
    private func cardView(for data: ChatCardData) -> some View {
        switch data {
        case .transaction(let txData):
            TransactionChatCard(data: txData, isDeleted: message.isEntityDeleted(for: .finance)) {
                onCardTap?(message, data)
            } onConfirm: {
                onTransactionConfirm?(message)
            } onCancel: {
                onTransactionCancel?(message)
            } onModifyCategory: {
                onTransactionModifyCategory?(message)
            }
        case .task(let taskData):
            TaskChatCard(data: taskData, isDeleted: message.isEntityDeleted(for: .task)) {
                onCardTap?(message, data)
            } onConfirm: {
                onTaskConfirm?(message)
            }
        case .habitCheckIn(let habitData):
            HabitCheckInChatCard(data: habitData) {
                onCardTap?(message, data)
            }
        case .mood(let moodData):
            MoodChatCard(data: moodData) {
                onCardTap?(message, data)
            }
        case .weight(let weightData):
            WeightChatCard(data: weightData) {
                onCardTap?(message, data)
            }
        case .analysisSummary(let summaryData):
            AnalysisSummaryChatCard(data: summaryData)
        case .analysisTrend(let trendData):
            AnalysisTrendChatCard(data: trendData)
        case .analysisBreakdown(let breakdownData):
            AnalysisBreakdownChatCard(data: breakdownData)
        case .analysisComparison(let comparisonData):
            AnalysisComparisonChatCard(data: comparisonData)
        case .analysisHighlights(let highlightsData):
            AnalysisHighlightsChatCard(data: highlightsData)
        case .flexibleQuery(let queryData):
            FlexibleQueryChatCard(data: queryData) { transactionId in
                onFlexibleQueryTransactionTap?(transactionId)
            } onViewAllTap: {
                onFlexibleQueryViewAllTap?(queryData)
            }
        }
    }

    // MARK: - Intent Tag

    private func intentTag(_ intentStr: String) -> some View {
        guard let intent = AIIntent(rawValue: intentStr) else {
            return AnyView(EmptyView())
        }
        let canTap: Bool
        if intent.isFinance {
            canTap = message.hasLinkedEntity(for: .finance)
        } else if intent.isTask {
            canTap = message.hasLinkedEntity(for: .task)
        } else if intent == .generateMemoryInsight {
            canTap = message.hasLinkedEntity(for: .memoryInsight)
        } else {
            canTap = false
        }

        return AnyView(
            Button {
                if canTap {
                    onIntentTagTap?(message)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: intentIcon(intent))
                        .font(.system(size: 10))
                    Text(intentLabel(intent))
                        .font(.system(size: 11))
                    if canTap {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.holoPrimary.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        )
    }

    private func intentIcon(_ intent: AIIntent) -> String {
        switch intent {
        case .recordExpense, .recordIncome: return "yensign.circle"
        case .createTask: return "checklist"
        case .completeTask: return "checkmark.circle"
        case .updateTask: return "pencil.circle"
        case .deleteTask: return "trash.circle"
        case .recordMood: return "heart.circle"
        case .checkIn: return "flame.circle"
        case .createNote: return "note.text"
        case .queryTasks: return "list.bullet.circle"
        case .queryHabits: return "chart.circle"
        case .recordWeight: return "figure.scale"
        case .unknown: return "questionmark.circle"
        default: return "sparkles"
        }
    }

    private func intentLabel(_ intent: AIIntent) -> String {
        switch intent {
        case .recordExpense, .recordIncome: return "已记账"
        case .createTask: return "已创建任务"
        case .completeTask: return "已完成任务"
        case .updateTask: return "已更新任务"
        case .deleteTask: return "已删除任务"
        case .recordMood: return "已记录心情"
        case .recordWeight: return "已记录体重"
        case .checkIn: return "已打卡"
        case .createNote: return "已记录笔记"
        case .queryTasks: return "任务查询"
        case .queryHabits: return "习惯查询"
        default: return intent.chatDisplayLabel
        }
    }
}

// MARK: - Equatable（隔离流式刷新：message 不变时跳过 body 重算）

extension MessageBubbleView: Equatable {
    /// 只比较影响渲染外观的字段，闭包不参与比较（其 identity 在 ChatView 父视图中稳定）。
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message
            && lhs.streamingText == rhs.streamingText
            && lhs.goalDraftForReview == rhs.goalDraftForReview
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isUser {
            // 用户消息：右下角有小尾巴
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height - tailSize), cornerSize: CGSize(width: radius, height: radius))
        } else {
            // AI 消息：左下角有小尾巴
            path.addRoundedRect(in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height - tailSize), cornerSize: CGSize(width: radius, height: radius))
        }

        return path
    }
}
