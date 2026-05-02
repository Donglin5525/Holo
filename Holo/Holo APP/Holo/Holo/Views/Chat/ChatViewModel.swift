//
//  ChatViewModel.swift
//  Holo
//
//  对话核心 ViewModel
//  管理消息收发、意图识别、流式对话
//

import Foundation
import Combine
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

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatViewModel")
    private let initialHistoryLimit = 30
    private var chatRepo: ChatMessageRepository?
    private var currentTask: Task<Void, Never>?
    private var provider: AIProvider
    private let coordinator: ConversationCoordinator
    private var repositoryBootstrapTask: Task<Void, Never>?
    private var repoMessagesCancellable: AnyCancellable?

    // MARK: - Init

    /// init 不做任何 I/O 操作，避免 Core Data / Keychain 阻塞主线程
    init(provider: AIProvider? = nil, coordinator: ConversationCoordinator? = nil) {
        self.provider = provider ?? MockAIProvider()
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
            try? await Task.sleep(nanoseconds: 250_000_000)
            await repo.loadMessagesAsync(limit: self.initialHistoryLimit)
            self.hasLoadedMessages = true
            self.repositoryBootstrapTask = nil
        }
    }

    private func ensureChatRepositoryReady() async {
        let repo: ChatMessageRepository

        if let chatRepo {
            repo = chatRepo
        } else {
            repo = ChatMessageRepository.shared
            bindRepository(repo)
        }

        if !hasLoadedMessages {
            await repo.loadMessagesAsync(limit: initialHistoryLimit)
            hasLoadedMessages = true
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

        // 1. 保存用户消息
        let userMessageId = chatRepo.addMessage(role: "user", content: text)

        // 2. 创建 AI 占位消息
        let aiMessageId = chatRepo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)

        // 3. 处理用户输入
        isStreaming = true
        streamingText = ""

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

                if processResult.shouldStreamChat {
                    if let analysisContext = processResult.analysisContext {
                        // 分析查询路径：零历史消息，独立 system context
                        let contextJSON = Self.encodeAnalysisContext(analysisContext)

                        let stream = self.provider.chatStreaming(
                            messages: [],
                            userContext: UserContext.empty,
                            systemContextOverride: contextJSON,
                            promptType: .analysisPrompt
                        )

                        var fullText = ""
                        for try await chunk in stream {
                            if Task.isCancelled { break }
                            fullText += chunk
                            self.streamingText = fullText
                        }

                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fullText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch),
                            analysisContextJSON: contextJSON
                        )
                    } else {
                        // 标准查询路径 → 流式对话
                        guard let chatRepo = self.chatRepo else { return }
                        let historyDTOs = chatRepo.toDTOs(from: chatRepo.loadRecentMessages(limit: 20))
                        let stream = self.provider.chatStreaming(messages: historyDTOs, userContext: userContext)

                        var fullText = ""
                        for try await chunk in stream {
                            if Task.isCancelled { break }
                            fullText += chunk
                            self.streamingText = fullText
                        }

                        // 原子化写入：结束流式 + 元数据，单次 save + 单次 snapshot
                        self.chatRepo?.finalizeMessage(
                            aiMessageId,
                            finalContent: fullText,
                            intent: processResult.firstIntent?.rawValue,
                            extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                            parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                            executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch)
                        )
                    }
                } else {
                    // 操作结果 / 澄清 / 错误 → 原子化写入
                    self.chatRepo?.finalizeMessage(
                        aiMessageId,
                        finalContent: processResult.finalText,
                        intent: processResult.firstIntent?.rawValue,
                        extractedDataJSON: Self.encodeExtractedData(processResult.firstExtractedData),
                        parsedBatchJSON: Self.encodeParseBatch(processResult.parsedBatch),
                        executionBatchJSON: Self.encodeExecutionBatch(processResult.executionBatch)
                    )
                }

                // ENERGY: 能量恢复预留位

            } catch is CancellationError {
                self.chatRepo?.finishStreaming(aiMessageId, finalContent: self.streamingText)
            } catch {
                self.logger.error("AI 处理失败：\(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                let errorText = "抱歉，处理时出错了：\(error.localizedDescription)"
                self.chatRepo?.finishStreaming(aiMessageId, finalContent: errorText)
            }

            self.isStreaming = false
            self.streamingText = ""
        }
    }

    // MARK: - Cancel

    func cancelStreaming() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Helpers

    /// 将 extractedData 字典编码为 JSON 字符串
    private static func encodeExtractedData(_ data: [String: String]?) -> String? {
        guard let data = data, !data.isEmpty else { return nil }
        do {
            let encoded = try JSONEncoder().encode(data)
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

// MARK: - Quick Actions

    func sendQuickAction(_ action: QuickAction) {
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
        }
    }
}
