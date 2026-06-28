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
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamingText: String = ""
    @Published var errorMessage: String?
    @Published var isConfigured: Bool = false
    @Published var isLoadingConfig: Bool = false
    @Published private(set) var hasFinishedSetup: Bool = false
    @Published private(set) var hasLoadedMessages: Bool = false
    @Published private(set) var didTimeoutLoadingConfig: Bool = false
    @Published private(set) var hasEarlierSessions: Bool = false
    @Published private(set) var isLoadingEarlierSession: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatViewModel")
    private let initialHistoryLimit = 30
    private var chatRepo: ChatMessageRepository?
    private var currentTask: Task<Void, Never>?
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

    @Published var capabilities: [HoloAICapability] = HoloAICapabilityProvider.visibleCapabilities(context: .empty)

    // MARK: - Goal Planning

    @Published private(set) var activeGoalPlanningSession: GoalPlanningSession?
    @Published var goalDraftForReview: GoalDraft?
    @Published var showGoalDraftReview = false
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
    }

    /// 在 .task 中调用，延迟初始化仓库和加载配置
    /// 流程：先读取 Keychain 配置，再在后台补加载消息仓库
    func setup() async {
        if hasFinishedSetup { return }
        bootstrapChatRepositoryIfNeeded()

        if HoloBackendEnvironment.isEnabledByDefault && !usesInjectedProvider {
            provider = HoloBackendEnvironment.makeDefaultProvider()
            isConfigured = true
            isLoadingConfig = false
            didTimeoutLoadingConfig = false
            hasFinishedSetup = true
            logger.info("AI 已配置为 Holo 后端网关")
            return
        }

        isLoadingConfig = true
        didTimeoutLoadingConfig = false
        defer {
            isLoadingConfig = false
            hasFinishedSetup = true
        }

        enum SetupResult {
            case config(AIProviderConfig?)
            case timeout
        }

        let result = await withTaskGroup(of: SetupResult.self) { group in
            group.addTask {
                let config = try? KeychainService.loadAIConfigOffMain()
                return .config(config)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch result {
        case .config(let config):
            if let config = config, config.isConfigured {
                provider = OpenAICompatibleProvider(config: config)
                isConfigured = true
                KeychainService.updateCachedAIConfigPresence(true)
                logger.info("AI 已配置为 \(config.provider.displayName)")
            } else {
                provider = MockAIProvider()
                isConfigured = false
                KeychainService.updateCachedAIConfigPresence(false)
            }
        case .timeout:
            didTimeoutLoadingConfig = true
            if KeychainService.hasCachedAIConfig {
                isConfigured = true
            }
            logger.error("AI 配置读取超时，先允许页面继续渲染")
        }
    }

    private func bootstrapChatRepositoryIfNeeded() {
        guard chatRepo == nil, repositoryBootstrapTask == nil else { return }

        repositoryBootstrapTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let repo = ChatMessageRepository.shared
            self.bindRepository(repo)
            repo.cleanupOrphanedStreamingMessages()
            try? await Task.sleep(nanoseconds: 250_000_000)
            await repo.loadCurrentSessionLightweightMessagesAsync(limit: self.initialHistoryLimit)
            self.hasLoadedMessages = true
            self.syncHasEarlierSessions()
            self.repositoryBootstrapTask = nil
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
            repo.cleanupOrphanedStreamingMessages()
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
                self?.messages = messages
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
        isConfigured = !(provider is MockAIProvider)
    }

    // MARK: - Send Message

    func sendMessage() async {
        await retryConfigurationLoadIfNeeded()
        await ensureChatRepositoryReady()
        guard let chatRepo = chatRepo else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

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

                // ENERGY: 能量检查预留位

                // 深度 Agent 分流（Phase 6.2）：命中则启动本地 Agent，不走流式分析
                if processResult.shouldRouteToAgent {
                    self.chatRepo?.setAnalysisLoadingState(
                        aiMessageId,
                        intent: "query_analysis",
                        analysisContext: nil
                    )
                    self.streamingText = "Holo 正在为你深度分析本地数据…建议先停留在当前界面；切到后台后会短时间继续尝试，回到 App 后可继续查看结果。"
                    let rendered = await self.analysisService.runAnalysis(question: text)
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

                        // 传递实际 userContext（含 profileSnapshot）而非 empty
                        // Provider 内部会从 userContext.profileSnapshot 读取 profile 注入
                        let stream = self.provider.chatStreaming(
                            messages: [],
                            userContext: userContext,
                            systemContextOverride: contextJSON,
                            promptType: .analysisPrompt
                        )

                        var fullText = ""
                        for try await chunk in stream {
                            if Task.isCancelled { break }
                            fullText += chunk
                            self.streamingText = fullText
                        }

                        let chatLog = self.provider.lastCallLog
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fullText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            analysisContextJSON: contextJSON,
                            rawLogJSON: Self.encodeRawLog(
                                intentLog: processResult.intentCallLog,
                                chatLog: chatLog,
                                chatResponseText: fullText
                            )
                        )
                    } else {
                        // 标准查询路径 → 流式对话
                        guard let chatRepo = self.chatRepo else { return }
                        let historyDTOs = await chatRepo.loadRecentDTOsAsync(limit: 20)
                        let stream = self.provider.chatStreaming(messages: historyDTOs, userContext: userContext)

                        var fullText = ""
                        for try await chunk in stream {
                            if Task.isCancelled { break }
                            fullText += chunk
                            self.streamingText = fullText
                        }

                        // 原子化写入：结束流式 + 元数据，单次 save + 单次 snapshot
                        let chatLog = self.provider.lastCallLog
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fullText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            rawLogJSON: Self.encodeRawLog(
                                intentLog: processResult.intentCallLog,
                                chatLog: chatLog,
                                chatResponseText: fullText
                            )
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
                        rawLogJSON: Self.encodeRawLog(
                            intentLog: processResult.intentCallLog,
                            chatLog: nil
                        )
                    )
                }

                // ENERGY: 能量恢复预留位

            } catch is CancellationError {
                self.chatRepo?.finishStreaming(aiMessageId, finalContent: self.streamingText)
            } catch {
                self.logger.error("AI 处理失败：\(error.localizedDescription)")
                self.errorMessage = error.localizedDescription

                // 保留已接收的部分内容，追加错误提示而非完全覆盖
                let partialContent = self.streamingText
                let finalContent: String
                if partialContent.isEmpty {
                    finalContent = "抱歉，处理时出错了：\(error.localizedDescription)"
                } else {
                    finalContent = partialContent + "\n\n---\n⚠️ 处理中断：\(error.localizedDescription)"
                }

                self.chatRepo?.finishStreaming(aiMessageId, finalContent: finalContent)
            }

            self.isStreaming = false
            self.streamingText = ""
            self.streamingWatchdogTask?.cancel()
            self.streamingWatchdogTask = nil
        }
    }

    // MARK: - Cancel

    func cancelStreaming() {
        currentTask?.cancel()
        currentTask = nil
        streamingWatchdogTask?.cancel()
        streamingWatchdogTask = nil
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

        // 检查已加载消息中是否有匹配的关联实体
        let hasAffectedMessages = messages.contains { message in
            for category in [EntityCategory.finance, .task] {
                if let entityId = message.resolveLinkedEntityId(for: category),
                   affectedIds.contains(entityId) {
                    return true
                }
            }
            return false
        }

        if hasAffectedMessages {
            objectWillChange.send()
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

                let intent: AIIntent = renderData["pendingKind"] == "transaction"
                    ? (currentItems.intent == .recordIncome ? .recordIncome : .recordExpense)
                    : currentItems.intent

                let result = ParsedResult(
                    intent: intent,
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
                    self.markTransactionAsAICreated(txId, candidate: renderData["categoryCandidate"] ?? renderData["note"])
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
                    renderData: renderData,
                    routeResult: routeResult,
                    intent: intent
                )

                // 归纳学习：记录样本并尝试触发 LLM 归纳
                self.recordInductionSampleIfNeeded(
                    renderData: renderData,
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

    /// 组装 LLM 调用日志并编码为 JSON
    private static func encodeRawLog(
        intentLog: LLMCallLog?,
        chatLog: LLMCallLog?,
        chatResponseText: String? = nil
    ) -> String? {
        var calls: [LLMCallLog] = []
        if let log = intentLog { calls.append(log) }
        if var log = chatLog {
            if let text = chatResponseText { log.responseText = text }
            calls.append(log)
        }
        guard !calls.isEmpty else { return nil }
        do {
            let encoded = try JSONEncoder().encode(LLMLog(calls: calls))
            return String(data: encoded, encoding: .utf8)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ChatViewModel")
                .error("编码 rawLog 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func retryConfigurationLoadIfNeeded() async {
        guard provider is MockAIProvider else { return }

        enum RetryResult {
            case config(AIProviderConfig?)
            case timeout
        }

        let result = await withTaskGroup(of: RetryResult.self) { group in
            group.addTask {
                let config = try? KeychainService.loadAIConfigOffMain()
                return .config(config)
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        guard case .config(let config) = result,
              let config,
              config.isConfigured else {
            return
        }

        provider = OpenAICompatibleProvider(config: config)
        isConfigured = true
        didTimeoutLoadingConfig = false
        KeychainService.updateCachedAIConfigPresence(true)
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
        }
        Task { await sendMessage() }
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
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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

    /// 加载更早会话，返回加载前首条消息的上一条消息 id（滚动锚点）
    func loadEarlierSession() async -> UUID? {
        guard !isLoadingEarlierSession else { return nil }
        isLoadingEarlierSession = true
        defer { isLoadingEarlierSession = false }
        return await chatRepo?.loadEarlierSessionLightweightMessagesAsync()
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
