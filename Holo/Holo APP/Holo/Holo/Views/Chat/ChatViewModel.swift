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

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var streamingText: String = ""
    @Published var errorMessage: String?
    @Published var isConfigured: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.holo.app", category: "ChatViewModel")
    private let chatRepo: ChatMessageRepository
    private var currentTask: Task<Void, Never>?
    private var provider: AIProvider

    // MARK: - Init

    init(
        chatRepo: ChatMessageRepository = .shared,
        provider: AIProvider? = nil
    ) {
        self.chatRepo = chatRepo
        self.provider = provider ?? MockAIProvider()
        self.messages = chatRepo.messages
        checkConfiguration()
    }

    // MARK: - Configuration

    /// 切换 AI Provider
    func updateProvider(_ newProvider: AIProvider) {
        self.provider = newProvider
        checkConfiguration()
    }

    /// 使用保存的配置创建真实 Provider
    func configureFromSavedConfig() {
        do {
            if let config = try KeychainService.shared.loadAIConfig(), config.isConfigured {
                provider = OpenAICompatibleProvider(config: config)
                isConfigured = true
                logger.info("AI 已配置为 \(config.provider.displayName)")
            } else {
                provider = MockAIProvider()
                isConfigured = false
            }
        } catch {
            logger.error("加载 AI 配置失败：\(error.localizedDescription)")
            provider = MockAIProvider()
            isConfigured = false
        }
    }

    private func checkConfiguration() {
        isConfigured = !(provider is MockAIProvider)
    }

    // MARK: - Send Message

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        errorMessage = nil

        // 1. 保存用户消息
        let userMessage = chatRepo.addMessage(role: "user", content: text)
        messages = chatRepo.messages

        // 2. 创建 AI 占位消息
        let aiMessage = chatRepo.addStreamingMessage(role: "assistant", parentMessageId: userMessage.id)
        messages = chatRepo.messages

        // 3. 处理用户输入
        isStreaming = true
        streamingText = ""

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // 构建上下文
                let userContext = await UserContextBuilder.shared.buildContext()

                // 先做意图识别
                let parsedResult = try await self.provider.parseUserInput(text, context: userContext)

                if parsedResult.isHighConfidence && parsedResult.intent != .chat && parsedResult.intent != .query {
                    // 高置信度非聊天意图 → 直接执行本地操作
                    let resultText = try await IntentRouter.shared.route(parsedResult)

                    // 更新 AI 消息
                    self.chatRepo.finishStreaming(aiMessage, finalContent: resultText)
                    self.chatRepo.updateMessageMetadata(
                        aiMessage,
                        intent: parsedResult.intent.rawValue,
                        extractedDataJSON: Self.encodeExtractedData(parsedResult.extractedData)
                    )
                } else {
                    // 低置信度或闲聊 → 流式对话
                    let historyDTOs = self.chatRepo.toDTOs(from: self.chatRepo.loadRecentMessages(limit: 20))

                    let stream = self.provider.chatStreaming(messages: historyDTOs, userContext: userContext)

                    var fullText = ""
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        fullText += chunk
                        self.streamingText = fullText
                    }

                    self.chatRepo.finishStreaming(aiMessage, finalContent: fullText)
                }

                self.messages = self.chatRepo.messages
            } catch is CancellationError {
                self.chatRepo.finishStreaming(aiMessage, finalContent: self.streamingText)
                self.messages = self.chatRepo.messages
            } catch {
                self.logger.error("AI 处理失败：\(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                let errorText = "抱歉，处理时出错了：\(error.localizedDescription)"
                self.chatRepo.finishStreaming(aiMessage, finalContent: errorText)
                self.messages = self.chatRepo.messages
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
        return (try? JSONEncoder().encode(data)).flatMap { String(data: $0, encoding: .utf8) }
    }

// MARK: - Quick Actions

    func sendQuickAction(_ action: QuickAction) {
        inputText = action.prompt
        Task { await sendMessage() }
    }

    // MARK: - Clear

    func clearMessages() {
        chatRepo.clearAllMessages()
        messages = []
    }
}

// MARK: - Quick Action

enum QuickAction: String, CaseIterable {
    case recordExpense = "记一笔消费"
    case createTask = "创建任务"
    case recordMood = "记录心情"
    case checkIn = "习惯打卡"
    case weeklyReport = "本周总结"

    var prompt: String {
        switch self {
        case .recordExpense: return "帮我记一笔消费"
        case .createTask: return "帮我创建一个任务"
        case .recordMood: return "记录我现在的心情"
        case .checkIn: return "帮我打卡"
        case .weeklyReport: return "生成本周总结"
        }
    }

    var icon: String {
        switch self {
        case .recordExpense: return "yensign.circle"
        case .createTask: return "checklist"
        case .recordMood: return "heart.circle"
        case .checkIn: return "flame.circle"
        case .weeklyReport: return "chart.bar"
        }
    }
}
