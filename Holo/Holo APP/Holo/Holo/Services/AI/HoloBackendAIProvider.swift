//
//  HoloBackendAIProvider.swift
//  Holo
//
//  调用 Holo 自有后端网关的 AI Provider
//

import Foundation
import os.log

@MainActor
final class HoloBackendAIProvider: AIProvider {

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloBackendAIProvider")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String
    private let promptService: HoloBackendPromptService
    private(set) var lastCallLog: LLMCallLog?

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId },
        promptService: HoloBackendPromptService = .shared
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
        self.promptService = promptService
    }

    // MARK: - AIProvider

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        let batch = try await parseUserInputBatch(input, context: context)
        return batch.first?.asParsedResult ?? ParsedResult(
            intent: .unknown,
            confidence: 0.3,
            extractedData: nil,
            needsClarification: batch.needsClarification,
            clarificationQuestion: batch.clarificationQuestion,
            responseText: batch.fallbackResponseText
        )
    }

    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
        let systemPrompt = await loadManagedPrompt(.intentRecognition)
        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .user(input)
        ]

        let request = buildRequest(
            purpose: .intent,
            messages: messages,
            responseFormat: .jsonObject
        )
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            type: "intent_recognition",
            model: "holo-backend",
            requestMessages: messages,
            responseText: content
        )

        return parseBatchFromJSON(content)
    }

    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult {
        let promptResult = await loadManagedPromptResult(.memoryInsightGeneration)
        let messages: [ChatMessageDTO] = [
            .system(promptResult.content),
            .user(contextJSON)
        ]
        let request = buildRequest(purpose: .insight, messages: messages, responseFormat: .jsonObject)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return MemoryInsightGenerationResult(
            rawResponse: content,
            promptType: "memory_insight_generation",
            promptVersion: promptResult.version
        )
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        let allMessages = await buildChatMessages(messages: messages, userContext: userContext)
        let request = buildRequest(purpose: .chat, messages: allMessages)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return content
    }

    /// 使用自定义 purpose 的非流式 chat 调用（不注入 UserContext）
    func chat(messages: [ChatMessageDTO], purpose: HoloBackendPurpose) async throws -> String {
        let request = buildRequest(purpose: purpose, messages: messages)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return content
    }

    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error> {
        chatStreaming(
            messages: messages,
            userContext: userContext,
            systemContextOverride: nil,
            promptType: .systemPrompt
        )
    }

    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let systemPrompt = await loadManagedPrompt(promptType)
                var allMessages: [ChatMessageDTO] = [.system(systemPrompt)]

                if let systemContextOverride {
                    allMessages.append(.system(systemContextOverride))
                } else {
                    allMessages.append(.system(buildContextMessage(userContext)))
                }

                allMessages.append(contentsOf: messages)

                let request = buildRequest(
                    purpose: .chat,
                    messages: allMessages,
                    stream: true
                )

                lastCallLog = LLMCallLog(
                    type: "chat",
                    model: "holo-backend",
                    requestMessages: allMessages,
                    responseText: ""
                )

                do {
                    for try await chunk in apiClient.sendStreaming(request) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Building

    private func buildRequest(
        purpose: HoloBackendPurpose,
        messages: [ChatMessageDTO],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil
    ) -> APIRequest {
        APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/chat/completions",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: HoloBackendChatCompletionRequest(
                purpose: purpose.rawValue,
                messages: messages,
                stream: stream,
                responseFormat: responseFormat
            )
        )
    }

    private func buildChatMessages(messages: [ChatMessageDTO], userContext: UserContext) async -> [ChatMessageDTO] {
        let systemPrompt = await loadManagedPrompt(.systemPrompt)
        var allMessages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(buildContextMessage(userContext))
        ]
        allMessages.append(contentsOf: messages)
        return allMessages
    }

    private func loadManagedPrompt(_ type: PromptManager.PromptType) async -> String {
        do {
            return try await promptService.loadPrompt(type)
        } catch {
            logger.warning("后端 Prompt 加载失败，回退本地默认模板：\(type.rawValue), \(error.localizedDescription)")
            return (try? PromptManager.shared.loadPrompt(type)) ?? PromptManager.shared.loadDefaultTemplate(type)
        }
    }

    private func loadManagedPromptResult(_ type: PromptManager.PromptType) async -> LoadedPrompt {
        do {
            return try await promptService.loadPromptResult(type)
        } catch {
            logger.warning("后端 Prompt 加载失败，回退本地默认模板：\(type.rawValue), \(error.localizedDescription)")
            let content = (try? PromptManager.shared.loadPrompt(type)) ?? PromptManager.shared.loadDefaultTemplate(type)
            return LoadedPrompt(type: type, version: 0, content: content)
        }
    }

    private func buildContextMessage(_ context: UserContext) -> String {
        var message = """
        当前用户上下文：
        - 日期：\(context.todayDate)
        - 今日支出：\(context.transactions.todayExpense)，今日收入：\(context.transactions.todayIncome)
        - 近期交易：\(context.transactions.recentTransactions.joined(separator: "、"))
        - 可用账户：\(context.accounts.accountList)
        - 活跃习惯：\(context.habits.totalActive) 个，今日完成 \(context.habits.todayCompleted)/\(context.habits.todayTotal)
        - 今日任务：\(context.tasks.todayTotal) 个（已完成 \(context.tasks.todayCompleted)），逾期 \(context.tasks.overdueCount) 个
        - 近期任务：\(context.tasks.recentTasks.joined(separator: "、"))
        - 近期想法：\(context.thoughts.recentThoughts.prefix(3).joined(separator: "、"))
        """

        let habitFocusLines = context.habits.focusSummaries.map(\.aiContextLine) + context.habits.focusTopicLines
        if !habitFocusLines.isEmpty {
            message += "\n\n--- 习惯关注主题 ---"
            message += "\n- " + habitFocusLines.joined(separator: "\n- ")
            message += "\n规则：负向习惯/减少型目标（如戒烟、抽烟、少喝酒、熬夜）发生越多不是越好；优先看发生总量下降、超标天数减少、控制率提升。"
        }

        if let profile = context.profileContext, !profile.isEmpty {
            message += "\n\n--- 用户档案 ---\n\(profile)"
        }

        if let trend = context.recentTrend {
            var trendSection = "\n\n--- 近期趋势 ---"
            trendSection += "\n- 本周支出：\(trend.weekExpenseTotal)"
            if let change = trend.weekExpenseChange {
                trendSection += "（较上周\(change)）"
            }
            if let rate = trend.weekHabitCompletionRate {
                trendSection += "\n- 本周习惯完成率：\(rate)"
            }
            trendSection += "\n- 本周完成任务：\(trend.weekTaskCompletedCount) 个"
            if let category = trend.topExpenseCategory {
                trendSection += "\n- 本周最大支出分类：\(category)"
            }
            if let summary = trend.dailyInsightSummary {
                trendSection += "\n- 今日洞察：\(summary)"
            }
            message += trendSection
        }

        if let goalContext = context.goalContext, !goalContext.isEmpty {
            message += "\n\n" + goalContext
        }

        return message
    }

    // MARK: - JSON Parsing

    private func parseBatchFromJSON(_ text: String) -> AIParseBatch {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            return AIParseBatch(
                mode: .clarification,
                items: [],
                needsClarification: true,
                clarificationQuestion: "我没完全理解这句话，你可以拆开再说一次吗？",
                fallbackResponseText: text
            )
        }

        if let batch = try? JSONDecoder().decode(AIParseBatch.self, from: data) {
            return batch
        }

        if let single = try? JSONDecoder().decode(ParsedResult.self, from: data) {
            let mode: AIInteractionMode = single.intent.isQuery ? .query : .singleAction
            return AIParseBatch(
                mode: mode,
                items: [single.asParseItem],
                needsClarification: single.needsClarification,
                clarificationQuestion: single.clarificationQuestion,
                fallbackResponseText: single.responseText
            )
        }

        logger.error("后端 AI JSON 解析失败，回退为 clarification")
        logger.error("LLM 原始返回：\(text)")

        return AIParseBatch(
            mode: .clarification,
            items: [],
            needsClarification: true,
            clarificationQuestion: "我没完全理解这句话，你可以拆开再说一次吗？",
            fallbackResponseText: text
        )
    }

    private func extractJSON(from text: String) -> String {
        if let range = text.range(of: "```json") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text
    }
}

enum HoloBackendPurpose: String {
    case chat
    case intent
    case insight
    case thoughtVoiceSummary = "thought_voice_summary"
}

struct HoloBackendChatCompletionRequest: Encodable {
    let purpose: String
    let messages: [ChatMessageDTO]
    let stream: Bool
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case purpose, messages, stream
        case responseFormat = "response_format"
    }
}

final class HoloBackendDeviceIdentity {
    static let shared = HoloBackendDeviceIdentity()

    private let key = "holo.backend.deviceId"
    private let userDefaults: UserDefaults

    var deviceId: String {
        if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let created = UUID().uuidString
        userDefaults.set(created, forKey: key)
        return created
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
}
