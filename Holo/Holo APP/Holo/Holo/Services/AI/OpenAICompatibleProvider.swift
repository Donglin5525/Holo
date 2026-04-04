//
//  OpenAICompatibleProvider.swift
//  Holo
//
//  OpenAI 兼容 API 通用实现
//  一套代码支持 DeepSeek、通义千问、Moonshot、智谱等国内 LLM
//

import Foundation
import os.log

@MainActor
final class OpenAICompatibleProvider: AIProvider {

    private let logger = Logger(subsystem: "com.holo.app", category: "OpenAICompatibleProvider")
    private let config: AIProviderConfig
    private let apiClient: APIClient

    init(config: AIProviderConfig, apiClient: APIClient = .shared) {
        self.config = config
        self.apiClient = apiClient
    }

    // MARK: - AIProvider

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        let systemPrompt = try PromptManager.shared.loadPrompt(.intentRecognition)
        let contextMessage = buildContextMessage(context)

        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(contextMessage),
            .user(input)
        ]

        let request = buildRequest(messages: messages)

        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        // 尝试解析 JSON 格式的 ParsedResult
        return try parseResultFromJSON(content, fallbackIntent: .chat, fallbackText: content)
    }

    func generateInsight(type: InsightType, data: UserContext) async throws -> String {
        let systemPrompt = try PromptManager.shared.loadPrompt(.insightGeneration)
        let contextMessage = buildContextMessage(data)

        let userMessage: String
        switch type {
        case .dailySummary:
            userMessage = "请生成今日总结"
        case .weeklyReport:
            userMessage = "请生成本周报告"
        case .monthlyReport:
            userMessage = "请生成本月报告"
        case .habitAnalysis:
            userMessage = "请分析我的习惯数据"
        case .financeAnalysis:
            userMessage = "请分析我的财务数据"
        }

        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(contextMessage),
            .user(userMessage)
        ]

        let request = buildRequest(messages: messages)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return content
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        let systemPrompt = try PromptManager.shared.loadPrompt(.systemPrompt)
        let contextMessage = buildContextMessage(userContext)

        var allMessages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(contextMessage)
        ]
        allMessages.append(contentsOf: messages)

        let request = buildRequest(messages: allMessages)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return content
    }

    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error> {
        do {
            let systemPrompt = try PromptManager.shared.loadPrompt(.systemPrompt)
            let contextMessage = buildContextMessage(userContext)

            var allMessages: [ChatMessageDTO] = [
                .system(systemPrompt),
                .system(contextMessage)
            ]
            allMessages.append(contentsOf: messages)

            let request = buildRequest(messages: allMessages, stream: true)
            return apiClient.sendStreaming(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    // MARK: - Private Helpers

    private func buildRequest(messages: [ChatMessageDTO], stream: Bool = false) -> APIRequest {
        APIRequest(
            baseURL: config.baseURL,
            path: "/chat/completions",
            method: .post,
            headers: [
                "Authorization": "Bearer \(config.apiKey)",
                "Content-Type": "application/json"
            ],
            body: ChatCompletionRequest(
                model: config.model,
                messages: messages,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                stream: stream
            )
        )
    }

    private func buildContextMessage(_ context: UserContext) -> String {
        """
        当前用户上下文：
        - 日期：\(context.todayDate)
        - 今日支出：\(context.transactions.todayExpense)，今日收入：\(context.transactions.todayIncome)
        - 近期交易：\(context.transactions.recentTransactions.joined(separator: "、"))
        - 活跃习惯：\(context.habits.totalActive) 个，今日完成 \(context.habits.todayCompleted)/\(context.habits.todayTotal)
        - 今日任务：\(context.tasks.todayTotal) 个（已完成 \(context.tasks.todayCompleted)），逾期 \(context.tasks.overdueCount) 个
        - 近期任务：\(context.tasks.recentTasks.joined(separator: "、"))
        - 近期想法：\(context.thoughts.recentThoughts.prefix(3).joined(separator: "、"))
        """
    }

    /// 从 AI 返回的 JSON 文本中解析 ParsedResult
    /// 如果 JSON 解析失败，降级为普通聊天
    private func parseResultFromJSON(_ text: String, fallbackIntent: AIIntent, fallbackText: String) throws -> ParsedResult {
        // 尝试提取 JSON（AI 可能在 JSON 前后加额外文字）
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            return ParsedResult(
                intent: fallbackIntent,
                confidence: 0.3,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: fallbackText
            )
        }

        do {
            let result = try JSONDecoder().decode(ParsedResult.self, from: data)
            return result
        } catch {
            logger.warning("ParsedResult JSON 解析失败，降级为普通聊天")
            return ParsedResult(
                intent: fallbackIntent,
                confidence: 0.3,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: fallbackText
            )
        }
    }

    /// 从文本中提取 JSON 内容
    private func extractJSON(from text: String) -> String {
        // 尝试提取 ```json ... ``` 中的内容
        if let range = text.range(of: "```json") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 尝试提取 { ... }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text
    }
}
