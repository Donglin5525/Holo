//
//  ChatViewModel.swift
//  Holo
//
//  对话核心 ViewModel
//  管理消息收发、意图识别、流式对话
//

import Foundation
import Combine
import CoreData
import os.log

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessageViewData] = []
    @Published var inputText: String = "" {
        didSet {
            UserDefaults.standard.set(inputText, forKey: Self.inputDraftKey)
        }
    }
    @Published var isStreaming: Bool = false
    /// AI 数据处理授权未开启时，点发送触发此提示（替代静默失败）
    @Published var showConsentPrompt: Bool = false
    @Published var streamingText: String = ""
    @Published var errorMessage: String?
    @Published var memoryNotice: String?
    @Published var isConfigured: Bool = false
    @Published var isLoadingConfig: Bool = false
    @Published private(set) var hasFinishedSetup: Bool = false
    @Published private(set) var hasLoadedMessages: Bool = false
    @Published private(set) var didTimeoutLoadingConfig: Bool = false
    @Published private(set) var hasEarlierSessions: Bool = false
    @Published private(set) var isLoadingEarlierSession: Bool = false
    @Published private(set) var earlierHistoryLoadFailed: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatViewModel")
    /// 首屏只装载足够覆盖约 3～5 屏的内容，降低复杂卡片首次布局的尖峰。
    private let initialHistoryLimit = 24
    /// 输入草稿持久化 key（退出界面再回来恢复未发送的文字）
    private static let inputDraftKey = "holo_chat_inputDraft"
    private var chatRepo: ChatMessageRepository?
    private var currentTask: Task<Void, Never>?
    /// 当前请求对应的占位消息；用于停止时立即关闭持久化 streaming 状态，
    /// 并防止已经取消的旧 Task 晚返回后覆盖下一次请求的 UI。
    private var activeStreamingMessageID: UUID?
    private var provider: AIProvider
    private let coordinator: ConversationCoordinator
    /// 本地深度 Agent 分析服务（Phase 6.2 灰度，agentRuntimeEnabled 把关）
    private let analysisService = HoloAgentAnalysisService()
    private var repositoryBootstrapTask: Task<Void, Never>?
    private var confirmingItemIds: Set<String> = []
    private var repoMessagesCancellable: AnyCancellable?
    private var metadataLoadPendingIds: Set<UUID> = []
    private var metadataLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var streamingWatchdogTask: Task<Void, Never>?
    private let usesInjectedProvider: Bool
    private var coreDataObserver: NSObjectProtocol?

    // MARK: - Capability Launchpad

    /// 空状态卡片使用的能力入口（含 onboarding 引导等，按用户状态动态生成）。
    @Published private(set) var emptyStateCapabilities: [HoloAICapability] = []

    /// 输入框上方常驻能力行使用的能力入口（今日状态/最近分析/规划目标等常驻项）。
    @Published private(set) var persistentCapabilities: [HoloAICapability] = HoloAICapabilityProvider.persistentCapabilities()

    /// 是否处于真正的空会话（历史消息加载完成且无消息）。
    /// 用于区分「加载中的假空」与「加载完成的真空」，避免空状态 UI 闪烁出现又消失。
    var isTrulyEmptyConversation: Bool {
        hasLoadedMessages && messages.isEmpty
    }

    /// 根据当前用户状态刷新能力入口（onboarding、数据充足度、记忆状态等）。
    /// 在 setup 完成、消息加载完成后调用，让 Provider 的动态分支真正生效。
    private func refreshCapabilities() {
        let context = HoloAICapabilityProviderContext(
            hasSufficientData: hasSufficientDataForCapabilities,
            hasLongTermMemories: hasLongTermMemoriesForCapabilities,
            hasLongTermCandidates: hasLongTermCandidatesForCapabilities,
            onboardingCompleted: LightweightOnboardingSettings.isCompleted
        )
        emptyStateCapabilities = HoloAICapabilityProvider.emptyStateCapabilities(context: context)
        persistentCapabilities = HoloAICapabilityProvider.persistentCapabilities(context: context)
    }

    /// 数据/记忆状态判定（目前保守返回 false，后续可接入记忆仓库细化）。
    private var hasSufficientDataForCapabilities: Bool { false }
    private var hasLongTermMemoriesForCapabilities: Bool { false }
    private var hasLongTermCandidatesForCapabilities: Bool { false }

    // MARK: - Goal Planning

    @Published private(set) var activeGoalPlanningSession: GoalPlanningSession?
    @Published var goalDraftForReview: GoalDraft?
    @Published var showGoalDraftReview = false
    /// 周期回放选择 Sheet（从记忆长廊迁移而来）
    @Published var showPeriodReplayPicker = false
    private let goalPlanningCoordinator = GoalPlanningCoordinator()

    // MARK: - Init

    /// init 不做任何 I/O 操作，避免 Core Data / Keychain 阻塞主线程
    deinit {
        if let observer = coreDataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    init(provider: AIProvider? = nil, coordinator: ConversationCoordinator? = nil) {
        self.usesInjectedProvider = provider != nil
        self.provider = provider ?? HoloBackendEnvironment.makeDefaultProvider()
        self.coordinator = coordinator ?? ConversationCoordinator()
        checkConfiguration()
        if KeychainService.hasCachedAIConfig {
            isConfigured = true
        }
        // 恢复未发送的输入草稿
        inputText = UserDefaults.standard.string(forKey: Self.inputDraftKey) ?? ""
    }

    /// 在 .task 中调用，延迟初始化仓库和加载配置
    /// 流程：先读取 Keychain 配置，再在后台补加载消息仓库
    func setup() async {
        if hasFinishedSetup { return }
        bootstrapChatRepositoryIfNeeded()

        if !usesInjectedProvider {
            provider = HoloBackendEnvironment.makeDefaultProvider()
        }
        isConfigured = true
        isLoadingConfig = false
        didTimeoutLoadingConfig = false
        hasFinishedSetup = true
        // 初始化时按当前 onboarding 状态生成空状态卡片内容（消息加载后再刷新一次）
        refreshCapabilities()
        logger.info("AI 已配置为 Holo 后端网关")
    }

    private func bootstrapChatRepositoryIfNeeded() {
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
            }
        }
    }

    private func ensureChatRepositoryReady() async {
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
                self.messages = messages
                self.isStreaming = messages.contains { $0.isStreaming }
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

    // MARK: - Configuration

    /// 切换 AI Provider
    func updateProvider(_ newProvider: AIProvider) {
        self.provider = newProvider
        checkConfiguration()
    }

    private func checkConfiguration() {
        isConfigured = true
    }

    // MARK: - Send Message

    func sendMessage() async {
        await retryConfigurationLoadIfNeeded()
        await ensureChatRepositoryReady()
        guard let chatRepo = chatRepo else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            showConsentPrompt = true
            return
        }

        inputText = ""
        errorMessage = nil

        // 目标规划分流
        if let session = activeGoalPlanningSession, session.status == .collecting {
            await handleGoalPlanningReply(text, session: session)
            return
        }

        if let session = activeGoalPlanningSession, session.status == .draftReady {
            errorMessage = "目标草案正在等待确认，请先处理当前草案。"
            inputText = text
            return
        }

        // 1. 保存用户消息
        let userMessageId = chatRepo.addMessage(role: "user", content: text)

        // 2. 创建 AI 占位消息
        let aiMessageId = chatRepo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)

        // 3. 处理用户输入
        isStreaming = true
        streamingText = ""
        activeStreamingMessageID = aiMessageId

        startStreamingWatchdog(aiMessageId: aiMessageId)

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 构建上下文
                let userContext = await UserContextBuilder.shared.buildContext()

                // ENERGY: 锁定检查预留位

                // 通过 Coordinator 处理（支持多动作）
                let processResult = try await self.coordinator.process(
                    text: text,
                    userContext: userContext,
                    provider: self.provider
                )
                try Task.checkCancellation()

                // ENERGY: 能量检查预留位

                // 深度 Agent 分流（Phase 6.2）：命中则启动本地 Agent，不走流式分析
                if processResult.shouldRouteToAgent {
                    self.streamingWatchdogTask?.cancel()
                    self.streamingWatchdogTask = nil
                    self.chatRepo?.setAnalysisLoadingState(
                        aiMessageId,
                        intent: processResult.firstIntent?.rawValue ?? "query_analysis",
                        analysisContext: nil
                    )
                    let initialStatus = HoloAgentChatStatus(
                        title: "Holo 正在深度分析中…",
                        detail: "可以离开当前页面；系统支持时会继续处理，中止后会保留进度并在回到 App 后恢复。",
                        keepsMessageStreaming: true,
                        showsActivityIndicator: true
                    )
                    self.chatRepo?.updateAgentMessageProgress(aiMessageId, status: initialStatus)
                    self.streamingText = initialStatus.messageContent
                    let rendered = await self.analysisService.runAnalysis(
                        question: text,
                        sourceMessageID: aiMessageId
                    )
                    try Task.checkCancellation()
                    // 额度耗尽走专属卡片（与普通聊天路径一致）：档位限制不是系统错误，
                    // 渲染 QuotaExhaustedChatCard + "了解 Holo Plus"入口，不写 agentResultJSON。
                    if case .quotaExhausted(let userMessage)? = rendered.failure {
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: userMessage,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: nil,
                            messageType: .quotaExhausted
                        )
                    } else {
                        // 不再拍扁成单段文本：结构化存 agentResultJSON，由 AgentDeepAnalysisCard 渲染
                        // fallback 文本用于历史回看/解码失败时退化展示（标题 + 摘要）
                        let fallbackText = [rendered.title, rendered.summary]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fallbackText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: nil,
                            parsedBatchJSON: nil,
                            executionBatchJSON: nil,
                            analysisContextJSON: nil,
                            rawLogJSON: nil,
                            agentResultJSON: Self.encodeAgentResult(rendered)
                        )
                    }
                } else if processResult.shouldStreamChat {
                    if let analysisContext = processResult.analysisContext {
                        // 立即设置 intent + analysisContext → 渲染 loading 卡片
                        self.chatRepo?.setAnalysisLoadingState(
                            aiMessageId,
                            intent: processResult.firstIntent?.rawValue,
                            analysisContext: analysisContext
                        )

                        // 分析查询路径：零历史消息，独立 system context
                        let contextJSON = Self.encodeAnalysisContext(analysisContext)
                        let memorySummary = await HoloMemorySummaryProvider.selectRelevantSummary(
                            purpose: .recentAnalysis,
                            queryText: text,
                            requireQueryMatch: true,
                            consumer: .analysis
                        )
                        let memoryEnvelope = HoloMemoryContextEnvelope.render(memorySummary)
                        let analysisSystemContext = [contextJSON, memoryEnvelope.isEmpty ? nil : memoryEnvelope]
                            .compactMap { $0 }
                            .joined(separator: "\n\n")

                        // 传递实际 userContext（含 profileSnapshot）而非 empty
                        // Provider 内部会从 userContext.profileSnapshot 读取 profile 注入
                        let stream = self.provider.chatStreaming(
                            messages: [],
                            userContext: userContext,
                            systemContextOverride: analysisSystemContext,
                            promptType: .analysisPrompt
                        )

                        var fullText = ""
                        var lastFlush = ContinuousClock.now
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            fullText += chunk
                            // 节流：合并到 ~30fps，避免每个 token 都触发整列表重绘
                            let now = ContinuousClock.now
                            if now - lastFlush > .milliseconds(33) {
                                self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)
                                lastFlush = now
                            }
                        }
                        // 流式结束前补齐最终累积文本，保证 consume 前的可见内容完整
                        self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)

                        let resolvedText = self.consumeMemoryUsageMarker(
                            from: fullText,
                            availableMemoryIDs: memorySummary.sourceIDs,
                            channel: .analysis
                        )
                        self.streamingText = resolvedText
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: resolvedText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            analysisContextJSON: contextJSON,
                            rawLogJSON: nil
                        )
                    } else {
                        // 标准查询路径 → 流式对话
                        guard let chatRepo = self.chatRepo else { return }
                        let historyDTOs = await chatRepo.loadRecentDTOsAsync(limit: 20)
                        let memorySummary = await HoloMemorySummaryProvider.selectRelevantSummary(
                            purpose: nil,
                            queryText: text,
                            requireQueryMatch: true,
                            consumer: .chat
                        )
                        var contextualUserContext = userContext
                        contextualUserContext.memorySummary = memorySummary
                        let stream = self.provider.chatStreaming(
                            messages: historyDTOs,
                            userContext: contextualUserContext
                        )

                        var fullText = ""
                        var lastFlush = ContinuousClock.now
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            fullText += chunk
                            // 节流：合并到 ~30fps，避免每个 token 都触发整列表重绘
                            let now = ContinuousClock.now
                            if now - lastFlush > .milliseconds(33) {
                                self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)
                                lastFlush = now
                            }
                        }
                        // 流式结束前补齐最终累积文本，保证 consume 前的可见内容完整
                        self.streamingText = HoloMemoryUsageMarker.visibleTextWhileStreaming(fullText)

                        let resolvedText = self.consumeMemoryUsageMarker(
                            from: fullText,
                            availableMemoryIDs: memorySummary.sourceIDs,
                            channel: .chat
                        )
                        self.streamingText = resolvedText
                        // 原子化写入：结束流式 + 元数据，单次 save + 单次 snapshot
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: resolvedText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            rawLogJSON: nil
                        )
                    }
                } else {
                    // 操作结果 / 澄清 / 错误 → 原子化写入
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: processResult.finalText,
                        intent: processResult.firstIntent?.rawValue,
                        extractedDataJSON: Self.encodeExtractedData(
                            processResult.firstExtractedData,
                            flexibleQueryResult: processResult.flexibleQueryResult
                        ),
                        parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                        executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                        rawLogJSON: nil
                    )
                }

                #if DEBUG || INTERNAL_DIAGNOSTICS
                let internalRequestIds = [
                    processResult.intentCallLog?.requestId,
                    self.provider.lastCallLog?.requestId
                ].compactMap { $0 }
                await HoloInternalLogService.shared.capture(
                    messageId: aiMessageId,
                    requestIds: Array(Set(internalRequestIds))
                )
                #endif

                // ENERGY: 能量恢复预留位

            } catch is CancellationError {
                // 用户点击停止时已经同步关闭这条消息；旧 Task 晚返回不得覆盖后续请求。
                if self.activeStreamingMessageID == aiMessageId {
                    self.chatRepo?.finishStreaming(aiMessageId, finalContent: self.streamingText)
                }
            } catch {
                // 这条请求已被用户停止，或已经有更新的请求接管输入栏。
                // URLSession 取消偶尔会被上游包装成普通网络错误，不能再把旧错误写回界面。
                guard self.activeStreamingMessageID == aiMessageId else { return }
                self.logger.error("AI 处理失败：\(error.localizedDescription)")

                // 配额耗尽走专属提示：档位限制不是系统错误，用 quotaExhausted 类型标记，
                // 渲染层据此展示柔和的额度卡片 + 「了解 Holo Plus」入口，而非红色错误样式。
                if let quotaError = error as? HoloQuotaError {
                    self.errorMessage = quotaError.userMessage
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: quotaError.userMessage,
                        intent: nil,
                        extractedDataJSON: nil,
                        parsedBatchJSON: nil,
                        executionBatchJSON: nil,
                        messageType: .quotaExhausted
                    )
                    return
                }

                let userMessage = HoloAIUserErrorMapper.message(for: error)
                self.errorMessage = userMessage

                // 保留已接收的部分内容，追加错误提示而非完全覆盖
                let partialContent = self.streamingText
                let finalContent: String
                if partialContent.isEmpty {
                    finalContent = userMessage
                } else {
                    finalContent = partialContent + "\n\n处理中断：\(userMessage)"
                }

                self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
            }

            if self.activeStreamingMessageID == aiMessageId {
                self.isStreaming = false
                self.streamingText = ""
                self.streamingWatchdogTask?.cancel()
                self.streamingWatchdogTask = nil
                self.currentTask = nil
                self.activeStreamingMessageID = nil
            }
        }
    }

    // MARK: - Cancel

    func cancelStreaming() {
        let cancelledMessageID = activeStreamingMessageID
        currentTask?.cancel()
        currentTask = nil
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = nil
        // 点击后立即结束输入栏的运行态；底层任务取消和持久化落盘继续异步完成。
        // 不能让按钮是否消失取决于网络请求何时响应取消。
        isStreaming = false
        streamingText = ""
        activeStreamingMessageID = nil
        if let cancelledMessageID {
            chatRepo?.finishStreaming(cancelledMessageID, finalContent: "已停止生成")
        }
        // 关键修复：Agent 深度分析跑在 Scheduler 独立 Task 上（activeTasks[jobID]），
        // 与 chat 的 currentTask 是不同对象。此前只取消 currentTask 对 Agent 无效，
        // 导致点「停止」后分析继续跑到预算耗尽。这里显式取消 Scheduler 上活跃的用户任务。
        // HoloAIFeatureFlags 守卫：未启用 Agent runtime 时不触发（避免无谓的 actor 调用）。
        if HoloAIFeatureFlags.agentRuntimeEnabled {
            Task { await HoloAgentScheduler.shared.cancelActiveUserQuestions() }
        }
    }

    // MARK: - Retry

    /// 重试发送：找到该错误消息对应的用户消息，重新发送
    func retryMessage(_ errorMessage: ChatMessageViewData) async {
        guard let parentId = errorMessage.parentMessageId,
              let userMessage = messages.first(where: { $0.id == parentId }) else { return }

        // 删除旧的错误消息
        chatRepo?.deleteMessage(errorMessage.id)

        // 用原始用户消息重新发送
        inputText = userMessage.content
        await sendMessage()
    }

    // MARK: - Streaming Watchdog

    /// 90 秒超时守护：如果 streaming 未在预期时间内完成，强制终止并恢复 UI
    private func startStreamingWatchdog(aiMessageId: UUID) {
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000) // 90s
            guard !Task.isCancelled else { return }
            guard self.activeStreamingMessageID == aiMessageId else { return }

            self.logger.error("Streaming watchdog 触发：90 秒超时，强制终止")

            self.currentTask?.cancel()
            self.currentTask = nil

            let partialContent = self.streamingText
            let finalContent: String
            if partialContent.isEmpty {
                finalContent = "抱歉，AI 响应超时了，请稍后重试"
            } else {
                finalContent = partialContent + "\n\n---\n⚠️ AI 响应超时，以上为已接收的部分内容"
            }

            self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
            self.isStreaming = false
            self.streamingText = ""
            self.errorMessage = "AI 响应超时"
            self.currentTask = nil
            self.activeStreamingMessageID = nil
        }
    }

    // MARK: - Core Data Change Observation

    /// 监听 CoreData 实体变更（删除/软删除），刷新受影响的卡片
    private func startObservingCoreDataChanges() {
        guard coreDataObserver == nil else { return }
        let context = CoreDataStack.shared.viewContext

        coreDataObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleCoreDataChange(notification)
            }
        }
    }

    private func stopObservingCoreDataChanges() {
        if let observer = coreDataObserver {
            NotificationCenter.default.removeObserver(observer)
            coreDataObserver = nil
        }
    }

    private func handleCoreDataChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        var affectedIds: Set<UUID> = []

        // 硬删除：Transaction、TodoTask 永久删除
        if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
            for object in deleted {
                if let transaction = object as? Transaction {
                    affectedIds.insert(transaction.id)
                }
                if let task = object as? TodoTask {
                    affectedIds.insert(task.id)
                }
            }
        }

        // 软删除/更新：TodoTask deletedFlag 变更
        if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
            for object in updated {
                if let task = object as? TodoTask {
                    affectedIds.insert(task.id)
                }
            }
        }

        guard !affectedIds.isEmpty else { return }

        // 命中受影响实体的消息：精准刷新其删除态缓存（缓存读自 snapshot，不能只发 willChange）
        var affectedMessageIDs: Set<UUID> = []
        for message in messages {
            for category in [EntityCategory.finance, .task] {
                if let entityId = message.resolveLinkedEntityId(for: category),
                   affectedIds.contains(entityId) {
                    affectedMessageIDs.insert(message.id)
                    break
                }
            }
        }

        for messageID in affectedMessageIDs {
            chatRepo?.refreshDeletionState(for: messageID, affectedCategories: [.finance, .task])
        }
    }

    // MARK: - Pending Task Confirmation

    func confirmPendingTask(from message: ChatMessageViewData) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent == .createTask && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }),
              let renderData = batch.items[pendingIndex].renderData else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      currentItems.renderData?["confirmationStatus"] == "pending" else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                let result = ParsedResult(
                    intent: .createTask,
                    confidence: 1,
                    extractedData: renderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = renderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let taskId = routeResult.taskId {
                    confirmedRenderData["taskId"] = taskId.uuidString
                }

                var updatedItems = batch.items
                let pending = updatedItems[pendingIndex]
                updatedItems[pendingIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: batch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )
            } catch {
                // 错误回写：标记卡片为 failed
                var failedRenderData = renderData
                failedRenderData["confirmationStatus"] = "failed"
                failedRenderData["errorText"] = error.localizedDescription

                var updatedItems = batch.items
                let pending = updatedItems[pendingIndex]
                updatedItems[pendingIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .failed,
                    summaryText: "创建任务失败",
                    renderData: failedRenderData,
                    linkedEntityType: nil,
                    linkedEntityId: nil,
                    errorText: error.localizedDescription
                )

                let failedBatch = AIExecutionBatch(
                    mode: batch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: failedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(failedBatch)
                )
                self.errorMessage = "创建任务失败：\(error.localizedDescription)"
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    private static func confirmedFinalText(from items: [AIExecutionItem]) -> String {
        guard !items.isEmpty else { return "已处理" }
        if items.count == 1 { return items[0].summaryText }
        return "已为你处理 \(items.count) 件事：\n" + items.enumerated().map { index, item in
            "\(index + 1). \(item.summaryText)"
        }.joined(separator: "\n")
    }

    // MARK: - Pending Transaction Confirmation

    func confirmPendingTransaction(from message: ChatMessageViewData) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }),
              batch.items[pendingIndex].renderData != nil else {
            return
        }

        let itemId = batch.items[pendingIndex].id
        guard !confirmingItemIds.contains(itemId) else { return }
        confirmingItemIds.insert(itemId)

        Task { @MainActor [weak self] in
            guard let self, let chatRepo = self.chatRepo else {
                self?.confirmingItemIds.remove(itemId)
                return
            }

            do {
                // 重读最新消息状态，防止过期数据重复确认
                guard let currentBatch = self.latestExecutionBatch(for: message.id),
                      let currentItems = currentBatch.items.first(where: { $0.id == itemId }),
                      let currentRenderData = currentItems.renderData,
                      currentRenderData["confirmationStatus"] == "pending" else {
                    self.confirmingItemIds.remove(itemId)
                    return
                }

                let intent: AIIntent = currentRenderData["pendingKind"] == "transaction"
                    ? (currentItems.intent == .recordIncome ? .recordIncome : .recordExpense)
                    : currentItems.intent

                let result = ParsedResult(
                    intent: intent,
                    confidence: 1,
                    extractedData: currentRenderData,
                    needsClarification: false,
                    clarificationQuestion: nil,
                    responseText: nil
                )
                let routeResult = try await IntentRouter.shared.route(result)

                var confirmedRenderData = currentRenderData
                confirmedRenderData["confirmationStatus"] = "confirmed"
                if let entity = routeResult.linkedEntity {
                    confirmedRenderData["entityType"] = entity.type.rawValue
                    confirmedRenderData["entityId"] = entity.id.uuidString
                }
                if let txId = routeResult.transactionId {
                    confirmedRenderData["transactionId"] = txId.uuidString
                }
                if let primary = routeResult.matchedPrimaryCategory {
                    confirmedRenderData["primaryCategory"] = primary
                }
                if let sub = routeResult.matchedSubCategory {
                    confirmedRenderData["subCategory"] = sub
                }

                // 写入 AI 来源标记
                if let txId = routeResult.transactionId {
                    self.markTransactionAsAICreated(txId, candidate: currentRenderData["categoryCandidate"] ?? currentRenderData["note"])
                }

                var updatedItems = batch.items
                let pending = updatedItems[pendingIndex]
                updatedItems[pendingIndex] = AIExecutionItem(
                    id: pending.id,
                    parseItemId: pending.parseItemId,
                    intent: pending.intent,
                    status: .success,
                    summaryText: routeResult.text,
                    renderData: confirmedRenderData,
                    linkedEntityType: routeResult.linkedEntity?.type.rawValue,
                    linkedEntityId: routeResult.linkedEntity?.id.uuidString,
                    errorText: nil
                )

                let updatedBatch = AIExecutionBatch(
                    mode: batch.mode,
                    items: updatedItems,
                    finalText: Self.confirmedFinalText(from: updatedItems)
                )

                chatRepo.updateMessage(message.id, content: updatedBatch.finalText)
                chatRepo.updateMessageMetadata(
                    message.id,
                    intent: message.intent,
                    extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
                    parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
                    executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
                )

                // 用户修改过分类时触发学习
                self.recordCategoryLearningIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                self.recordInductionSampleIfNeeded(
                    renderData: currentRenderData,
                    routeResult: routeResult,
                    intent: intent
                )
            } catch {
                self.writeTransactionError(itemId: itemId, batch: batch, message: message, error: error)
            }

            self.confirmingItemIds.remove(itemId)
        }
    }

    func cancelPendingTransaction(from message: ChatMessageViewData) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        guard var renderData = pending.renderData else { return }
        renderData["confirmationStatus"] = "cancelled"

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: "已取消记账",
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    /// AddTransactionSheet 编辑保存后，将待确认卡片标记为"已确认"（不重复创建交易）
    func dismissPendingCardAfterEdit(from message: ChatMessageViewData, createdTransaction: Transaction? = nil) {
        guard let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "confirmed"

        // 如果 AddTransactionSheet 创建了交易，补全分类和实体关联信息
        if let tx = createdTransaction, let category = tx.category {
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            renderData["primaryCategory"] = names.primary
            if let sub = names.sub {
                renderData["subCategory"] = sub
            }
            renderData["entityType"] = "finance"
            renderData["entityId"] = tx.id.uuidString
            renderData["transactionId"] = tx.id.uuidString

            // 标记为 AI 创建
            markTransactionAsAICreated(tx.id, candidate: renderData["categoryCandidate"] ?? renderData["note"])

            // 分类学习：将原始候选词映射到用户选择的正确分类
            let candidate = renderData["categoryCandidate"] ?? renderData["note"]
            if let candidateText = candidate, !candidateText.trimmingCharacters(in: .whitespaces).isEmpty {
                let txType: TransactionType = tx.transactionType
                CategoryLearnedMapping.record(
                    candidate: candidateText,
                    type: txType,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                CategoryLearnedMapping.recordInductionSample(
                    candidate: candidateText,
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
                CategoryLearnedMapping.tryTriggerInduction(
                    targetPrimary: names.primary,
                    targetSub: names.sub ?? names.primary,
                    transactionType: txType
                )
            }
        }

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .success,
            summaryText: "已确认并记录",
            renderData: renderData,
            linkedEntityType: createdTransaction != nil ? "finance" : pending.linkedEntityType,
            linkedEntityId: createdTransaction?.id.uuidString ?? pending.linkedEntityId,
            errorText: nil
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func writeTransactionError(
        itemId: String,
        batch: AIExecutionBatch,
        message: ChatMessageViewData,
        error: Error
    ) {
        guard let pendingIndex = batch.items.firstIndex(where: { $0.id == itemId }) else { return }
        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]
        renderData["confirmationStatus"] = "failed"
        renderData["confirmationError"] = error.localizedDescription

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: .skipped,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: error.localizedDescription
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: Self.confirmedFinalText(from: updatedItems)
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    private func latestExecutionBatch(for messageId: UUID) -> AIExecutionBatch? {
        guard let msg = messages.first(where: { $0.id == messageId }) else { return nil }
        return msg.executionBatch
    }

    // MARK: - Pending Transaction Category Update

    func updatePendingTransactionCategory(
        from message: ChatMessageViewData,
        category: Category
    ) {
        guard category.isSubCategory,
              let batch = message.executionBatch,
              let pendingIndex = batch.items.firstIndex(where: {
                  $0.intent.isFinance && $0.status == .skipped && $0.renderData?["confirmationStatus"] == "pending"
              }) else {
            return
        }

        let pending = batch.items[pendingIndex]
        var renderData = pending.renderData ?? [:]

        // 查找父分类名称
        let parentName = FinanceRepository.shared.parentCategoryName(for: category)
        renderData["primaryCategory"] = parentName
        renderData["subCategory"] = category.name
        renderData["selectedCategoryId"] = category.id.uuidString

        var updatedItems = batch.items
        updatedItems[pendingIndex] = AIExecutionItem(
            id: pending.id,
            parseItemId: pending.parseItemId,
            intent: pending.intent,
            status: pending.status,
            summaryText: pending.summaryText,
            renderData: renderData,
            linkedEntityType: pending.linkedEntityType,
            linkedEntityId: pending.linkedEntityId,
            errorText: pending.errorText
        )

        let updatedBatch = AIExecutionBatch(
            mode: batch.mode,
            items: updatedItems,
            finalText: batch.finalText
        )

        chatRepo?.updateMessage(message.id, content: updatedBatch.finalText)
        chatRepo?.updateMessageMetadata(
            message.id,
            intent: message.intent,
            extractedDataJSON: Self.encodeExtractedData(message.extractedDataDictionary),
            parsedBatchJSON: Self.encodeParseBatch(message.parsedBatch),
            executionBatchJSON: Self.encodeExecutionBatch(updatedBatch)
        )
    }

    // MARK: - Category Learning

    private func markTransactionAsAICreated(_ transactionId: UUID, candidate: String?) {
        FinanceRepository.shared.markTransactionAsAICreated(transactionId, candidate: candidate)
    }

    private func recordCategoryLearningIfNeeded(
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult,
        intent: AIIntent
    ) {
        // 只有用户通过 Sheet 修改过分类才触发学习
        guard renderData["selectedCategoryId"] != nil else { return }
        guard let candidate = renderData["categoryCandidate"] ?? renderData["note"],
              !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let targetPrimary = routeResult.matchedPrimaryCategory,
              let targetSub = routeResult.matchedSubCategory else { return }

        let type: TransactionType = intent == .recordIncome ? .income : .expense
        CategoryLearnedMapping.record(
            candidate: candidate,
            type: type,
            primaryCategory: renderData["primaryCategory"] ?? "",
            targetPrimary: targetPrimary,
            targetSub: targetSub
        )
        logger.info("记账分类学习：\(candidate) → \(targetPrimary)/\(targetSub)")
    }

    /// 归纳学习：记录样本并尝试触发 LLM 归纳
    private func recordInductionSampleIfNeeded(
        renderData: [String: String],
        routeResult: IntentRouter.RouteResult,
        intent: AIIntent
    ) {
        guard let candidate = renderData["categoryCandidate"] ?? renderData["note"],
              !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let targetPrimary = routeResult.matchedPrimaryCategory,
              let targetSub = routeResult.matchedSubCategory else { return }

        let type: TransactionType = intent == .recordIncome ? .income : .expense
        CategoryLearnedMapping.recordInductionSample(
            candidate: candidate,
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
        CategoryLearnedMapping.tryTriggerInduction(
            targetPrimary: targetPrimary,
            targetSub: targetSub,
            transactionType: type
        )
    }

    // MARK: - Helpers

    /// 将 extractedData 字典编码为 JSON 字符串
    private static func encodeExtractedData(
        _ data: [String: String]?,
        flexibleQueryResult: FlexibleQueryResult? = nil
    ) -> String? {
        var payload = data ?? [:]
        if let flexibleQueryResult,
           let resultData = try? JSONEncoder().encode(flexibleQueryResult),
           let resultJSON = String(data: resultData, encoding: .utf8) {
            payload["flexibleQueryResultJSON"] = resultJSON
        }
        guard !payload.isEmpty else { return nil }
        do {
            let encoded = try JSONEncoder().encode(payload)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 extractedData 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIParseBatch 编码为 JSON 字符串
    private static func encodeParseBatch(_ batch: AIParseBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 parsedBatch 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AIExecutionBatch 编码为 JSON 字符串
    private static func encodeExecutionBatch(_ batch: AIExecutionBatch?) -> String? {
        guard let batch = batch else { return nil }
        do {
            let encoded = try JSONEncoder().encode(batch)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 executionBatch 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 将 AnalysisContext 编码为 JSON 字符串
    private static func encodeAgentResult(_ result: HoloRenderedAgentResult) -> String? {
        guard let data = try? JSONEncoder().encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeAnalysisContext(_ context: AnalysisContext) -> String? {
        do {
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(context)
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 analysisContext 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func consumeMemoryUsageMarker(
        from text: String,
        availableMemoryIDs: [String],
        channel: HoloMemoryReceiptChannel
    ) -> String {
        let result = HoloMemoryUsageMarker.parseAndStrip(
            text,
            allowedMemoryIDs: Set(availableMemoryIDs)
        )
        if !result.usedMemoryIDs.isEmpty {
            let notice = "Holo 参考了 \(result.usedMemoryIDs.count) 条已记住的信息"
            HoloMemoryReceiptStore.record(
                kind: .use,
                channel: channel,
                memoryIDs: result.usedMemoryIDs,
                message: notice
            )
            memoryNotice = notice
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.memoryNotice == notice {
                    self?.memoryNotice = nil
                }
            }
        }
        return result.cleanText
    }

    private func retryConfigurationLoadIfNeeded() async {
        // 正式能力统一由 Holo 后端提供，不读取客户端模型配置。
    }

// MARK: - Capability Tap

    func handleCapabilityTap(_ capability: HoloAICapability) {
        switch capability.id {
        case .onboarding:
            inputText = "我是新用户，能教我怎么用 Holo 吗？"
        case .todayState:
            inputText = "帮我看看今天的整体状态"
        case .recentAnalysis:
            inputText = "分析一下我最近的数据趋势"
        case .longTermPatterns:
            inputText = "你了解我哪些长期偏好和模式？"
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
        await HoloPeriodReplayCoordinator.shared.start(
            periodType: periodType,
            start: start,
            end: end
        )
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
                    provider: provider
                )
                activeGoalPlanningSession = result.session
                if let question = result.assistantText {
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: question,
                        parentMessageId: userMessageId,
                        messageType: .goalPlanning
                    )
                }
                if let draft = result.draft {
                    goalDraftForReview = draft
                    let summary = "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)"
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
                    _ = chatRepo.addMessage(
                        role: "assistant",
                        content: quotaError.userMessage,
                        parentMessageId: userMessageId,
                        messageType: .quotaExhausted
                    )
                } else {
                    errorMessage = HoloAIUserErrorMapper.message(for: error)
                }
            }
        }
    }

    private func handleGoalPlanningReply(_ text: String, session: GoalPlanningSession) async {
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
                    content: question,
                    parentMessageId: userMessageId,
                    messageType: .goalPlanning
                )
            }
            if let draft = result.draft {
                goalDraftForReview = draft
                let summary = "已根据你的需求生成了目标计划「\(draft.title)」\(draft.cardSummary)"
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
                _ = chatRepo.addMessage(
                    role: "assistant",
                    content: quotaError.userMessage,
                    parentMessageId: userMessageId,
                    messageType: .quotaExhausted
                )
            } else {
                errorMessage = HoloAIUserErrorMapper.message(for: error)
            }
        }
    }

    func cancelGoalPlanning() {
        activeGoalPlanningSession?.status = .cancelled
        goalDraftForReview = nil
        showGoalDraftReview = false
        _ = chatRepo?.addMessage(
            role: "assistant",
            content: "已取消这次目标规划。",
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
            content: "已创建目标「\(result.goal.title)」，并生成 \(result.createdTaskCount) 个任务、\(result.createdHabitCount) 个习惯。",
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

// MARK: - Quick Action

enum QuickAction: String, CaseIterable {
    case recordExpense = "记一笔消费"
    case createTask = "创建任务"
    case recordMood = "记录心情"
    case checkIn = "习惯打卡"
    case weeklyReport = "本周总结"
    case createNote = "记笔记"
    case queryTasks = "今日任务"
    case queryHabits = "习惯状态"
    case planGoal = "规划目标"

    var prompt: String {
        switch self {
        case .recordExpense: return "帮我记一笔消费"
        case .createTask: return "帮我创建一个任务"
        case .recordMood: return "记录我现在的心情"
        case .checkIn: return "帮我打卡"
        case .weeklyReport: return "生成本周总结"
        case .createNote: return "帮我记一条笔记"
        case .queryTasks: return "今天有什么待办"
        case .queryHabits: return "今天习惯完成了吗"
        case .planGoal: return ""
        }
    }

    var icon: String {
        switch self {
        case .recordExpense: return "yensign.circle"
        case .createTask: return "checklist"
        case .recordMood: return "heart.circle"
        case .checkIn: return "flame.circle"
        case .weeklyReport: return "chart.bar"
        case .createNote: return "note.text"
        case .queryTasks: return "list.bullet.circle"
        case .queryHabits: return "chart.circle"
        case .planGoal: return "target"
        }
    }
}
