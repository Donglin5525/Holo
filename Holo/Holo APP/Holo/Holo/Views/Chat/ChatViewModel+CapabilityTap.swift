//
//  ChatViewModel+CapabilityTap.swift
//  Holo
//
//  ChatViewModel 机械拆分（体检 R0-51）：仅搬移，不改任何逻辑
//

import Foundation
import Combine
import CoreData
import os.log

extension ChatViewModel {
// MARK: - Capability Tap

    func handleCapabilityTap(_ capability: HoloAICapability) {
        switch capability.id {
        case .onboarding:
            inputText = String(localized: "我是新用户，能教我怎么用 Holo 吗？")
        case .todayState:
            // 确认权原则（2026-08-22 东林拍板）：预填不发送，
            // 与深度分析场景面板同一底线——用户看到并确认将发出的话再按发送。
            inputText = String(localized: "帮我看看今天的整体状态")
            return
        case .recentAnalysis:
            // 甲方案（2026-08-22）：不再点击即发——点开场景面板，
            // 由用户选场景并确认发送，发起的确认权在用户。
            showAnalysisScenarioPanel.toggle()
            return
        case .longTermPatterns:
            // 与「今日状态」同类：快问快答也走预填确认
            inputText = String(localized: "你了解我哪些长期偏好和模式？")
            return
        case .goalPlanning:
            startGoalPlanning(seedText: nil)
            return
        case .periodReplay:
            // 弹周期选择 Sheet，选完后走 startPeriodReplay（独立流程，不走 sendMessage）
            showPeriodReplayPicker = true
            return
        }
        Task { await sendMessage() }
    }

    // MARK: - Period Replay（周期回放，从记忆长廊迁移而来）

    /// 周期回放交给应用级协调器执行，页面销毁、息屏或冷启动都能从原消息继续。
    func startPeriodReplay(periodType: MemoryInsightPeriodType, start: Date, end: Date) async {
        // 云端回放轨道的首次确认（v2：含健康摘要说明）：未同意时本次走本地，下次生效
        if HoloAIFeatureFlags.cloudDeepAnalysisEnabled,
           !HoloCloudAnalysisService.privacyConsented {
            showCloudPrivacySheet = true
        } else if HoloCloudAnalysisService.shared.canTakeCloudTask() {
            // 云端接管即注册推送（「回放已生成」通知）；拒绝不影响生成
            HoloCloudPushTokenService.shared.requestAuthorizationAndRegister()
        }
        await HoloPeriodReplayCoordinator.shared.start(
            periodType: periodType,
            start: start,
            end: end
        )
    }

    /// 首页胶囊 / 系统通知直达洞察：把已生成的洞察直接落成回放卡片。
    /// 卡片落地即视为「看过」（方案 §7.5），随后刷新首页候选让胶囊让位；
    /// 洞察已不可用时什么都不做——不 markRead，胶囊保留。
    func openScheduledInsight(id: UUID) async {
        let repository = MemoryInsightRepository()
        guard let insight = repository.fetchAvailableInsight(id: id),
              insight.parsedPayload != nil else { return }
        try? repository.markRead(insight: insight)
        HomeScheduleService.shared.refresh()
        HoloPeriodReplayCoordinator.shared.presentCachedInsight(insight)
    }

    // MARK: - Quick Actions（兼容旧入口）

    func sendQuickAction(_ action: QuickAction) {
        if action == .planGoal {
            startGoalPlanning(seedText: nil)
            return
        }
        inputText = action.prompt
        Task { await sendMessage() }
    }

    // MARK: - Clear

    func clearMessages() {
        if chatRepo == nil {
            bootstrapChatRepositoryIfNeeded()
        }
        chatRepo?.clearAllMessages()
    }

    // MARK: - Metadata Lazy Load

    /// 触发单条消息的元数据加载（带 debounce 合并）
    func loadMetadataIfNeeded(for messageId: UUID) {
        metadataLoadPendingIds.insert(messageId)
        metadataLoadTask?.cancel()
        metadataLoadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
            guard !Task.isCancelled else { return }
            let ids = Array(self.metadataLoadPendingIds)
            self.metadataLoadPendingIds.removeAll()
            await self.chatRepo?.loadMetadataForMessagesIfNeeded(ids)
        }
    }

    // MARK: - Goal Planning

    func startGoalPlanning(seedText: String?) {
        Task { @MainActor in
            await retryConfigurationLoadIfNeeded()
            await ensureChatRepositoryReady()
            guard let chatRepo else { return }

            // 额度预检（先验票再进场）：目标规划与日常对话共用 chat 池，
            // 一次完整流程最多 3 轮追问 + 1 次草案生成。
            // - 余量连「一问一草案」（2 次）都撑不起 → 落付费墙卡片，不进问答流程；
            // - 余量跑不满 3 轮 → 按余量压缩追问轮数（宁可少问，不在用户认真作答后中途断）；
            // - 余量数据缺失（nil）→ 放行默认轮数，由后端拦截 + 额度卡片兜底。
            var planningMaxTurns = GoalPlanningSession.defaultMaxTurns
            if let remaining = HoloEntitlementState.shared.quotas["chat"]?.remaining {
                guard remaining > 1 else {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: HoloQuotaError.goalPlanningExhaustedMessage(
                            isPlusActive: HoloEntitlementState.shared.isPlusActive
                        ),
                        messageType: .quotaExhausted
                    )
                    return
                }
                planningMaxTurns = max(1, min(GoalPlanningSession.defaultMaxTurns, remaining - 1))
            }

            let userMessageId: UUID?
            if let seedText, !seedText.isEmpty {
                userMessageId = chatRepo.addMessage(role: "user", content: seedText, messageType: .goalPlanning)
            } else {
                userMessageId = nil
            }

            isStreaming = true
            defer {
                isStreaming = false
                streamingText = ""
            }

            do {
                let userContext = await UserContextBuilder.shared.buildContext()
                let result = try await goalPlanningCoordinator.start(
                    seedText: seedText,
                    userContext: userContext,
                    provider: provider,
                    maxTurns: planningMaxTurns
                )
                activeGoalPlanningSession = result.session
                if let question = result.assistantText {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: strippedGoalPlanningText(
                            question,
                            allowedMemoryIDs: userContext.memorySummary?.sourceIDs ?? []
                        ),
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
                if let draft = result.draft {
                    goalDraftForReview = draft
                    let summary = String(localized: "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)")
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: summary,
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
            } catch {
                if let quotaError = error as? HoloQuotaError {
                    errorMessage = quotaError.userMessage
                    // 额度按天重置是确定终态：会话不能继续占用聊天入口，
                    // 否则后续普通消息仍会被路由成规划回答、反复触发额度报错。
                    activeGoalPlanningSession = nil
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: quotaError.userMessage,
                        parentMessageId: userMessageId,
                        messageType: .quotaExhausted
                    )
                } else {
                    // errorMessage 没有界面消费点，失败必须落到气泡，否则用户发消息石沉大海
                    let userMessage = HoloAIUserErrorMapper.message(for: error)
                    errorMessage = userMessage
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: String(localized: "目标规划没有完成：\(userMessage) 可以再试一次，或直接用文字告诉我你的目标。"),
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
            }
        }
    }

    func handleGoalPlanningReply(_ text: String, session: GoalPlanningSession) async {
        guard let chatRepo else { return }
        inputText = ""
        errorMessage = nil
        let userMessageId = chatRepo.addMessage(role: "user", content: text, messageType: .goalPlanning)
        isStreaming = true
        defer {
            isStreaming = false
            streamingText = ""
        }

        do {
            let userContext = await UserContextBuilder.shared.buildContext()
            let result = try await goalPlanningCoordinator.handleUserReply(
                text,
                session: session,
                userContext: userContext,
                provider: provider
            )
                activeGoalPlanningSession = result.session
                if let question = result.assistantText {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: strippedGoalPlanningText(
                            question,
                            allowedMemoryIDs: userContext.memorySummary?.sourceIDs ?? []
                        ),
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
                if let draft = result.draft {
                    goalDraftForReview = draft
                    let summary = String(localized: "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)")
                    _ = chatRepo.addMessage(
                        role: "assistant",
                    content: summary,
                    parentMessageId: userMessageId,
                    messageType: .goalPlanning
                )
            }
        } catch {
            if let quotaError = error as? HoloQuotaError {
                errorMessage = quotaError.userMessage
                // 同 startGoalPlanning：额度终态必须释放会话，让聊天入口回到普通对话，
                // 不能让用户后续每条消息都被当成规划回答反复撞额度墙。
                activeGoalPlanningSession = nil
                _ = chatRepo.addMessage(
                    role: "assistant",
                    content: quotaError.userMessage,
                    parentMessageId: userMessageId,
                    messageType: .quotaExhausted
                )
            } else {
                // 同上：失败写气泡，避免静默失败
                let userMessage = HoloAIUserErrorMapper.message(for: error)
                errorMessage = userMessage
                _ = chatRepo.addMessage(
                    role: "assistant",
                    content: String(localized: "目标规划没有完成：\(userMessage) 可以再试一次，或直接用文字告诉我你的目标。"),
                    parentMessageId: userMessageId,
                    messageType: .goalPlanning
                )
            }
        }
    }

    func cancelGoalPlanning() {
        activeGoalPlanningSession?.status = .cancelled
        goalDraftForReview = nil
        showGoalDraftReview = false
        _ = chatRepo?.addMessage(
            role: "assistant",
            content: String(localized: "已取消这次目标规划。"),
            messageType: .goalPlanning
        )
        activeGoalPlanningSession = nil
    }

    func markGoalPlanningConfirmed() {
        activeGoalPlanningSession?.status = .confirmed
        goalDraftForReview = nil
        showGoalDraftReview = false
        activeGoalPlanningSession = nil
    }

    func finishGoalPlanningSave(_ result: GoalDraftSaveResult) {
        let extractedData: [String: String] = [
            "goalId": result.goal.id.uuidString,
            "goalTitle": result.goal.title,
            "createdTaskCount": "\(result.createdTaskCount)",
            "createdHabitCount": "\(result.createdHabitCount)"
        ]
        _ = chatRepo?.addMessage(
            role: "assistant",
            content: String(localized: "已创建目标「\(result.goal.title)」，并生成 \(result.createdTaskCount) 个任务、\(result.createdHabitCount) 个习惯。"),
            extractedDataJSON: Self.encodeExtractedData(extractedData),
            messageType: .goalPlanning
        )
        markGoalPlanningConfirmed()
    }

    // MARK: - Session History

    /// 小批量加载更早消息。视口保持由 ChatScrollController 负责，
    /// ViewModel 只暴露明确的成功/失败状态，便于顶部提供轻量重试。
    func loadEarlierSession() async -> ChatHistoryPageResult {
        guard !isLoadingEarlierSession else {
            return .loaded(0, hasEarlierMessages: hasEarlierSessions)
        }
        isLoadingEarlierSession = true
        earlierHistoryLoadFailed = false
        defer { isLoadingEarlierSession = false }

        guard let chatRepo else {
            earlierHistoryLoadFailed = true
            return .failed(hasEarlierMessages: hasEarlierSessions)
        }

        let result = await chatRepo.loadEarlierSessionLightweightMessagesAsync()
        earlierHistoryLoadFailed = result.didFail
        hasEarlierSessions = result.hasEarlierMessages
        return result
    }
}
