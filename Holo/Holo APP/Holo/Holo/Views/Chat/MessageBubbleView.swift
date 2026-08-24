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
    var onAgentScopeChange: ((AgentScopeChangePreset) -> Void)? = nil
    var onAgentResumePaused: (() -> Void)? = nil
    var onPeriodReplayExpansionChanged: ((ChatMessageViewData, Bool) -> Void)? = nil
    var onGoalDraftCardTap: (() -> Void)? = nil
    var onSavedGoalCardTap: ((UUID) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    /// 额度耗尽卡片「了解 Holo Plus」点击，由上层导航到会员中心
    var onLearnPlus: (() -> Void)? = nil
    var onCardDelete: ((ChatMessageViewData, UUID, EntityCategory, String) -> Void)? = nil
    var onTaskConfirm: ((ChatMessageViewData, TaskCardData) -> Void)? = nil
    /// 任务卡片「取消」：取消待确认的创建/修改/删除
    var onTaskCancel: ((ChatMessageViewData, TaskCardData) -> Void)? = nil
    /// 任务卡片「补充条目」：锚定该任务继续对话修改条目
    var onTaskFollowUp: ((ChatMessageViewData, TaskCardData) -> Void)? = nil
    var onTransactionConfirm: ((ChatMessageViewData, TransactionCardData) -> Void)? = nil
    var onTransactionCancel: ((ChatMessageViewData, TransactionCardData) -> Void)? = nil
    var onTransactionModifyCategory: ((ChatMessageViewData, TransactionCardData) -> Void)? = nil
    var onBudgetConfirm: ((ChatMessageViewData, BudgetChatCardData) -> Void)? = nil
    /// 预算卡片「取消」：取消待确认的预算设置
    var onBudgetCancel: ((ChatMessageViewData, BudgetChatCardData) -> Void)? = nil
    var onAnniversaryConfirm: ((ChatMessageViewData, AnniversaryChatCardData) -> Void)? = nil
    /// 纪念日卡片「取消」：取消待确认的创建
    var onAnniversaryCancel: ((ChatMessageViewData, AnniversaryChatCardData) -> Void)? = nil
    /// goalChoice 选择卡：点选候选目标确认执行
    var onGoalChoiceSelect: ((ChatMessageViewData, GoalChoiceCardData, GoalChoiceCandidate) -> Void)? = nil
    /// goalChoice 选择卡取消：不执行动作
    var onGoalChoiceCancel: ((ChatMessageViewData, GoalChoiceCardData) -> Void)? = nil
    /// 举报 AI 生成内容（App Store Guideline 1.2），仅对 AI 消息生效。
    var onReport: ((ChatMessageViewData) -> Void)? = nil
    /// 周计划卡：快照按台账实时读取（provider 注入，避免逐条查库阻塞渲染）
    var lifePlanSnapshotProvider: ((ChatMessageViewData) -> LifePlanSnapshot?)? = nil
    var lifePlanUndoPlanID: UUID? = nil
    var onLifePlanOpenReview: ((LifePlanSnapshot) -> Void)? = nil
    var onLifePlanUndo: ((LifePlanSnapshot) -> Void)? = nil

    private var displayText: String {
        streamingText ?? message.content
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

    var body: some View {
        Group {
            if isUser {
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 60)
                    messageContent
                    userAvatar
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    aiHeader
                    messageContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            // 删除记录（仅有关联实体且未删除的卡片消息；多卡消息逐张列出）
            if !isUser {
                ForEach(deletableCards, id: \.entityId) { info in
                    Button(role: .destructive) {
                        onCardDelete?(message, info.entityId, info.category, info.description)
                    } label: {
                        Label("删除\(info.description)", systemImage: "trash")
                    }
                }
            }
            // 举报 AI 生成内容（App Store Guideline 1.2）：对所有 AI 消息开放。
            if !isUser {
                Button {
                    onReport?(message)
                } label: {
                    Label("举报", systemImage: "exclamationmark.bubble")
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
    }

    @ViewBuilder
    private var messageContent: some View {
        let analysisCardsData = message.analysisCards
        let hasAnalysisCards = !analysisCardsData.isEmpty
        let cards = message.executionCards
        let hasCards = !cards.isEmpty
        let singleCard = message.singleCard
        let flexibleQueryCard = message.flexibleQueryCard

        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            // 渲染优先级：用户已停止 > 额度耗尽提示 > 已保存目标卡片 > 目标计划卡片 > 周期回放 > 分析卡片 > 批处理卡片 > 单卡片 > 通用文字。
            // 用户已停止的消息统一走纯文本气泡（显示「已停止生成」），
            // 不再残留 Agent 分析卡 / loading 态。
            if message.messageType == .userCancelled {
                bubbleContent
            } else if message.isQuotaExhausted {
                QuotaExhaustedChatCard(message: message.content, onLearnPlus: onLearnPlus)
            } else if let savedGoalCard = message.savedGoalCard {
                GoalSavedChatCard(data: savedGoalCard) {
                    onSavedGoalCardTap?(savedGoalCard.goalId)
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
            } else if message.messageType == .lifePlan {
                if let snapshot = lifePlanSnapshotProvider?(message) {
                    LifePlanChatCard(
                        snapshot: snapshot,
                        canUndo: lifePlanUndoPlanID == snapshot.id,
                        onOpenReview: { onLifePlanOpenReview?(snapshot) },
                        onUndo: { onLifePlanUndo?(snapshot) }
                    )
                } else {
                    bubbleContent
                }
            } else if message.isQueryAnalysis {
                if message.agentResult != nil || (message.isStreaming && message.analysisContext == nil) {
                    AgentDeepAnalysisCard(message: message) {
                        onAgentDeepAnalysisTap?()
                    } onScopeChange: { preset in
                        onAgentScopeChange?(preset)
                    } onResumePaused: {
                        onAgentResumePaused?()
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

    /// 删除菜单候选：按卡片粒度列出（多卡消息每张卡各带自己的实体 ID），
    /// 避免旧行为「只取第一个可删除实体」在多卡时删错对象
    private var deletableCards: [(category: EntityCategory, entityId: UUID, description: String)] {
        let allCards = message.executionCards.isEmpty ? (message.singleCard.map { [$0] } ?? []) : message.executionCards

        var result: [(EntityCategory, UUID, String)] = []
        for card in allCards {
            switch card {
            case .transaction(let data):
                if let id = data.entityID.flatMap(UUID.init(uuidString:))
                    ?? message.resolveLinkedEntityId(for: .finance),
                    !message.isEntityDeleted(for: .finance) {
                    result.append((.finance, id, "\(data.displayTitle) ¥\(data.amount)"))
                }
            case .task(let data):
                if let id = data.taskId ?? message.resolveLinkedEntityId(for: .task),
                    !message.isEntityDeleted(for: .task) {
                    result.append((.task, id, "任务「\(data.title)」"))
                }
            default:
                break
            }
        }
        return result
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

            Text("AI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(Capsule())

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Holo，AI 生成")
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
            VStack(alignment: .leading, spacing: 6) {
                AIReadableResponseView(
                    text: displayText,
                    isStreaming: message.isStreaming && streamingText != nil,
                    isError: message.isError,
                    onRetry: onRetry
                )
                // 记忆引用署名：流式结束后按持久化数据展示，不参与流式重绘
                if !message.isStreaming, let memoryCount = message.memoryAttributionCount {
                    MemoryAttributionBadge(count: memoryCount, memoryIDs: message.memoryAttributionIDs)
                }
            }
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
                onTransactionConfirm?(message, txData)
            } onCancel: {
                onTransactionCancel?(message, txData)
            } onModifyCategory: {
                onTransactionModifyCategory?(message, txData)
            }
        case .task(let taskData):
            TaskChatCard(data: taskData, isDeleted: message.isEntityDeleted(for: .task)) {
                onCardTap?(message, data)
            } onConfirm: {
                onTaskConfirm?(message, taskData)
            } onCancel: {
                onTaskCancel?(message, taskData)
            } onFollowUp: {
                onTaskFollowUp?(message, taskData)
            }
        case .budget(let budgetData):
            BudgetChatCard(data: budgetData) {
                onBudgetConfirm?(message, budgetData)
            } onCancel: {
                onBudgetCancel?(message, budgetData)
            }
        case .anniversary(let anniversaryData):
            AnniversaryChatCard(data: anniversaryData, isDeleted: message.isEntityDeleted(for: .anniversary)) {
                onCardTap?(message, data)
            } onConfirm: {
                onAnniversaryConfirm?(message, anniversaryData)
            } onCancel: {
                onAnniversaryCancel?(message, anniversaryData)
            }
        case .habitCheckIn(let habitData):
            // 当前习惯打卡卡片没有详情跳转入口，保持展示态，避免出现可点击但无动作的假交互。
            HabitCheckInChatCard(data: habitData)
        case .mood(let moodData):
            // 心情卡片当前只展示记录结果，暂未提供想法详情跳转。
            MoodChatCard(data: moodData)
        case .weight(let weightData):
            // 体重记录当前只展示结果，暂未提供习惯详情跳转。
            WeightChatCard(data: weightData)
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
        case .goalChoice(let choiceData):
            GoalChoiceChatCard(
                data: choiceData,
                onSelect: { candidate in
                    onGoalChoiceSelect?(message, choiceData, candidate)
                },
                onCancel: {
                    onGoalChoiceCancel?(message, choiceData)
                }
            )
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
        } else if intent == .createAnniversary || intent == .updateAnniversary {
            canTap = message.hasLinkedEntity(for: .anniversary)
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
                    Text(intent.chatDisplayLabel)
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
        case .setBudget: return "chart.pie"
        case .createTask: return "checklist"
        case .completeTask: return "checkmark.circle"
        case .updateTask: return "pencil.circle"
        case .deleteTask: return "trash.circle"
        case .recordMood: return "heart.circle"
        case .checkIn: return "flame.circle"
        case .createNote: return "note.text"
        case .createAnniversary, .updateAnniversary: return "calendar"
        case .queryTasks: return "list.bullet.circle"
        case .queryHabits: return "chart.circle"
        case .recordWeight: return "figure.scale"
        case .unknown: return "questionmark.circle"
        default: return "sparkles"
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
