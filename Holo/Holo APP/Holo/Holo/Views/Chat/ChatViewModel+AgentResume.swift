//
//  ChatViewModel+AgentResume.swift
//  Holo
//
//  ChatViewModel 机械拆分（体检 R0-51）：仅搬移，不改任何逻辑
//

import Foundation
import Combine
import CoreData
import os.log

extension ChatViewModel {
    // MARK: - Paused Agent Jobs Resume

    /// Chat 页兜底：存在暂停态（waitingForForeground/paused）的 Agent job 时拉起恢复链。
    /// 生命周期事件（回前台/解锁/冷启动）的恢复各有条件，一旦错过时机任务会一直停在
    /// 「已暂停」；页面就绪是用户注意力所在，此处兜底最可靠。
    /// Scheduler 唯一执行权 + manager 内部 cancel 旧任务，重复调用无副作用。
    func resumePausedAgentJobsIfNeeded() {
        guard !isStreaming else { return }
        HoloBackgroundContinuationManager.shared.resumePausedJobsForChatAppearance()
    }

    /// 暂停卡片「立即继续」按钮的手动入口（与自动兜底同一条恢复链）。
    /// 点击瞬间先把消息置为「正在继续分析…」——状态走消息管道立即上屏，
    /// 不等恢复链跑完才变样；之后由轮询/同步刷成真实进度。
    func resumePausedAgentJobs(sourceMessageID: UUID? = nil) {
        if let sourceMessageID, let repo = chatRepo {
            repo.updateAgentMessageProgress(
                sourceMessageID,
                status: HoloAgentChatStatusPresenter.resumingStatus()
            )
        }
        HoloBackgroundContinuationManager.shared.resumePausedJobsForChatAppearance()
    }

    func bootstrapChatRepositoryIfNeeded() {
        guard chatRepo == nil, repositoryBootstrapTask == nil else { return }

        repositoryBootstrapTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let repo = ChatMessageRepository.shared
            self.bindRepository(repo)

            // 消息加载先行，让首屏尽早上屏；Agent 状态校准与孤儿清理并行在后台进行。
            // sync/cleanup 完成后会通过 Repository.updateSnapshot 回主线程刷新受影响消息，
            // 极端情况（崩溃恢复有孤儿 streaming）首屏可能短暂显示占位，随后自动收敛。
            await repo.loadCurrentSessionLightweightMessagesAsync(limit: self.initialHistoryLimit)
            self.hasLoadedMessages = true
            self.syncHasEarlierSessions()
            // 消息加载完成后刷新能力入口（此时 isTrulyEmptyConversation 可靠）
            self.refreshCapabilities()
            self.repositoryBootstrapTask = nil

            // 后台并行：校准 Agent job 状态 + 清理孤儿 streaming 消息（不阻塞首屏）
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 注意：syncRecoverableChatMessages 已会回填完成的 Agent 结果，
                // 这里跑一次即可拿到准确的 preserve 集合，无需重复执行。
                let preserved = await self.analysisService.syncRecoverableChatMessages(repository: repo)
                    .union(HoloPeriodReplayCoordinator.shared.recoverableMessageIDs())
                await repo.cleanupOrphanedStreamingMessagesOffMain(preserveMessageIDs: preserved)
                self.resumePausedAgentJobsIfNeeded()
            }
        }
    }

    func ensureChatRepositoryReady() async {
        if let repositoryBootstrapTask {
            await repositoryBootstrapTask.value
            if chatRepo != nil, hasLoadedMessages {
                return
            }
        }

        let repo: ChatMessageRepository

        if let chatRepo {
            repo = chatRepo
        } else {
            repo = ChatMessageRepository.shared
            bindRepository(repo)
        }

        if !hasLoadedMessages {
            let preserved = await analysisService.syncRecoverableChatMessages(repository: repo)
                .union(HoloPeriodReplayCoordinator.shared.recoverableMessageIDs())
            await repo.cleanupOrphanedStreamingMessagesOffMain(preserveMessageIDs: preserved)
            await repo.loadCurrentSessionLightweightMessagesAsync(limit: initialHistoryLimit)
            // 上次确认流程若中途被杀，消息停在 confirming 态：对账防重复入账
            repo.reconcileInterruptedConfirmations()
            hasLoadedMessages = true
            syncHasEarlierSessions()
        }

        repositoryBootstrapTask = nil
    }

    private func bindRepository(_ repo: ChatMessageRepository) {
        guard chatRepo !== repo else { return }

        chatRepo = repo
        repoMessagesCancellable = repo.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.messages = Self.annotateTimestampSeparators(messages)
                // 全局 isStreaming（输入锁语义）只由「当前请求」的生命周期管理
                // （sendMessage 置 true / concludeStreamingSession 收尾），不得从消息级
                // streaming 重建：Agent 等待网络/前台的消息会把它反复顶回 true，
                // 把用户锁在聊天框外（最长等到 30 分钟截止）。停止键的可见性
                // 由 hasActiveStreamingMessage（消息级）覆盖等待场景。
            }

        // 同步 hasEarlierSessions
        repo.$hasEarlierSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.hasEarlierSessions = value
            }
            .store(in: &cancellables)

        startObservingCoreDataChanges()
    }

    private func syncHasEarlierSessions() {
        hasEarlierSessions = chatRepo?.hasEarlierSessions ?? false
    }

    /// 预计算每条消息是否需要在其上方显示时间分隔条。
    /// 首条消息或距上一条 ≥ 5 分钟时显示。在数据进入列表前一次性算好，
    /// 让 ForEach 不再依赖 enumerated() 复制整个数组、也不在渲染期逐条判断时间差。
    private static func annotateTimestampSeparators(_ messages: [ChatMessageViewData]) -> [ChatMessageViewData] {
        guard !messages.isEmpty else { return messages }
        var result = messages
        for index in result.indices {
            let previous = index > 0 ? result[index - 1].timestamp : nil
            result[index].showsTimestampSeparator = ChatTimeStampSeparator.shouldShow(
                current: result[index].timestamp,
                previous: previous
            )
        }
        return result
    }

    // MARK: - Configuration

    /// 切换 AI Provider
    func updateProvider(_ newProvider: AIProvider) {
        self.provider = newProvider
        checkConfiguration()
    }

    func checkConfiguration() {
        isConfigured = true
    }

    // MARK: - Agent Continuation

    /// 从已完成的 Result 建立输入栏锚点。只保存身份和展示摘要，
    /// 真正执行时由 Runtime 重新读取 canonical Job / Result / Evidence。
    func startContinuation(from result: HoloRenderedAgentResult) {
        guard result.failure == nil,
              let parentJobID = result.agentJobID,
              let parentResultID = result.agentResultID else {
            errorMessage = String(localized: "这份历史分析缺少可追溯依据，请重新发起一次分析。")
            return
        }

        continuationDraft = HoloAgentContinuationDraft(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            rootUserQuestion: result.rootUserQuestion
                ?? result.question
                ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            },
            relation: .explain
        )
        errorMessage = nil
    }

    func clearContinuationDraft() {
        continuationDraft = nil
    }

    /// 结果卡「换范围」：以显式窗口重跑同一分析（.changeScope 追问）。
    /// 范围由 UI 直接注入（userOverride），不经文本解析，确定性 100%；
    /// 聊天里会落一条「换成近半年再看」的用户消息，链路与手动追问完全一致。
    func changeAnalysisScope(from result: HoloRenderedAgentResult, preset: AgentScopeChangePreset) async {
        guard result.failure == nil,
              let parentJobID = result.agentJobID,
              let parentResultID = result.agentResultID else {
            errorMessage = String(localized: "这份历史分析缺少可追溯依据，请重新发起一次分析。")
            return
        }
        continuationDraft = HoloAgentContinuationDraft(
            parentJobID: parentJobID,
            parentResultID: parentResultID,
            rootUserQuestion: result.rootUserQuestion
                ?? result.question
                ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            },
            relation: .changeScope,
            overrideTimeRange: preset.timeRange()
        )
        errorMessage = nil
        inputText = preset.followUpText
        await sendMessage()
    }

    /// 显式锚定优先；没有锚定时，只在 4 小时内且包含明确承接词时自动继承最近 Result。
    /// “执行建议”交回原有动作确认链，避免分析 Agent 绕过确认直接改数据。
    func resolvedContinuationDraft(for text: String, now: Date = Date()) -> HoloAgentContinuationDraft? {
        if var explicitDraft = continuationDraft {
            let relation = HoloAgentFollowUpRouter.classify(
                followUpText: text,
                parent: HoloAgentFollowUpParentContext(
                    parentDomains: explicitDraft.parentDomains,
                    hasRecommendations: !explicitDraft.parentRecommendations.isEmpty
                )
            )
            switch relation {
            case .newTopic:
                continuationDraft = nil
                return nil
            case .executeFromResult:
                explicitDraft.relation = .executeFromResult
            case .ambiguous:
                // 用户已主动点击“继续追问”，不要因为句子短而丢失锚点。
                explicitDraft.relation = .explain
            default:
                explicitDraft.relation = relation
            }
            return explicitDraft
        }

        // 隐式承接只允许锚定“最近一条已完成的助手回复”。如果中间已经有普通聊天，
        // 即使四小时内存在更早的 Agent Result，也不能跨过新话题回捞旧结果。
        guard let parentMessage = messages.reversed().first(where: {
            $0.role == "assistant" && !$0.isStreaming
        }), let result = parentMessage.agentResult,
              result.failure == nil,
              result.agentJobID != nil,
              result.agentResultID != nil else {
            return nil
        }

        var draft = HoloAgentContinuationDraft(
            parentJobID: result.agentJobID ?? "",
            parentResultID: result.agentResultID ?? "",
            rootUserQuestion: result.rootUserQuestion ?? result.question ?? result.title,
            parentDomains: Array(Set(
                result.evidenceReferences.compactMap { $0.sourceModule?.rawValue }
            )).sorted(),
            parentRecommendations: (result.recommendations ?? []).map {
                HoloAgentContinuationDraft.RecommendationRef(
                    id: $0.id,
                    title: $0.title,
                    body: $0.body
                )
            }
        )
        let relation = HoloAgentFollowUpRouter.implicitRelation(
            text: text,
            parent: HoloAgentFollowUpParentContext(
                parentDomains: draft.parentDomains,
                hasRecommendations: !draft.parentRecommendations.isEmpty
            ),
            parentCompletedAt: parentMessage.timestamp,
            now: now
        )
        guard let relation else { return nil }
        draft.relation = relation
        return draft
    }

    /// “执行建议”只转换成待确认的任务草案，不直接落库。
    /// 多条建议且用户未指明序号时先做确定性澄清，避免替用户猜。
    func recommendationActionCommand(
        for draft: HoloAgentContinuationDraft,
        userText: String
    ) -> String? {
        guard let recommendation = selectedRecommendation(in: draft, userText: userText) else {
            return nil
        }
        return """
        创建一个待办草案，标题是“\(recommendation.title)”，补充说明是“\(recommendation.body)”。
        这条草案来自上一份分析建议；必须走现有确认流程，用户确认前不得写入任何数据。
        """
    }

    private func selectedRecommendation(
        in draft: HoloAgentContinuationDraft,
        userText: String
    ) -> HoloAgentContinuationDraft.RecommendationRef? {
        let recommendations = draft.parentRecommendations
        guard !recommendations.isEmpty else { return nil }
        if recommendations.count == 1 { return recommendations[0] }

        let normalized = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let exact = recommendations.first(where: {
            !$0.title.isEmpty && normalized.contains($0.title.lowercased())
        }) {
            return exact
        }

        let ordinalMarkers: [[String]] = [
            ["第一条", "第1条", "第 1 条", "建议1", "建议 1", "1号建议"],
            ["第二条", "第2条", "第 2 条", "建议2", "建议 2", "2号建议"],
            ["第三条", "第3条", "第 3 条", "建议3", "建议 3", "3号建议"],
            ["第四条", "第4条", "第 4 条", "建议4", "建议 4", "4号建议"],
            ["第五条", "第5条", "第 5 条", "建议5", "建议 5", "5号建议"]
        ]
        for (index, markers) in ordinalMarkers.enumerated()
            where index < recommendations.count
                && markers.contains(where: normalized.contains) {
            return recommendations[index]
        }
        return nil
    }

    func recommendationSelectionClarification(
        for draft: HoloAgentContinuationDraft
    ) -> ConversationProcessResult {
        let titles = draft.parentRecommendations.prefix(5).enumerated().map {
            "\($0.offset + 1). \($0.element.title)"
        }.joined(separator: "\n")
        return ConversationProcessResult(
            finalText: String(localized: "这份分析有多条建议，请告诉我要执行哪一条，例如“执行第 2 条”。\n\n\(titles)"),
            parsedBatch: nil,
            executionBatch: nil,
            firstIntent: nil,
            firstExtractedData: nil,
            shouldStreamChat: false,
            analysisContext: nil,
            flexibleQueryResult: nil,
            shouldRouteToAgent: false
        )
    }

    func safeActionHandoffFailure() -> ConversationProcessResult {
        ConversationProcessResult(
            finalText: String(localized: "我没能把这条建议可靠地转换成可确认的操作。你可以说“把第 2 条创建成待办”。"),
            parsedBatch: nil,
            executionBatch: nil,
            firstIntent: nil,
            firstExtractedData: nil,
            shouldStreamChat: false,
            analysisContext: nil,
            flexibleQueryResult: nil,
            shouldRouteToAgent: false
        )
    }
}
