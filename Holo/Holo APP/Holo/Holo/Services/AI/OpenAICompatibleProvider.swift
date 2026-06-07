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
    private(set) var lastCallLog: LLMCallLog?

    init(config: AIProviderConfig, apiClient: APIClient = .shared) {
        self.config = config
        self.apiClient = apiClient
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
        let systemPrompt = try PromptManager.shared.loadPrompt(.intentRecognition)

        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
            .user(input)
        ]

        let request = buildRequest(messages: messages, responseFormat: .jsonObject)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            type: "intent_recognition",
            model: config.model,
            requestMessages: messages,
            responseText: content
        )

        return parseBatchFromJSON(content)
    }

    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch {
        let systemPrompt = try PromptManager.shared.loadPrompt(kind.promptType)
        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
            .user(input)
        ]

        let request = buildRequest(messages: messages, responseFormat: .jsonObject)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            type: kind.promptType.rawValue,
            model: config.model,
            requestMessages: messages,
            responseText: content
        )

        return parseActionBatchFromJSON(content, kind: kind)
    }

    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult {
        let systemPrompt = try PromptManager.shared.loadPrompt(.memoryInsightGeneration)
        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .user(contextJSON)
        ]
        let request = buildRequest(messages: messages, temperature: 0.3)
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return MemoryInsightGenerationResult(
            rawResponse: content,
            promptType: "memory_insight_generation",
            promptVersion: nil
        )
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        let systemPrompt = try PromptManager.shared.loadPrompt(.systemPrompt)
        let contextMessage = AIUserContextMessageBuilder.build(from: userContext, purpose: .chat)

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
        do {
            let systemPrompt = try PromptManager.shared.loadPrompt(promptType)

            var allMessages: [ChatMessageDTO] = [
                .system(systemPrompt)
            ]

            // 分析模式：注入 context JSON 作为第二条 system message
            if let contextOverride = systemContextOverride {
                // 分析模式：先注入 profile（如开启），再注入分析 context JSON
                // Profile 放前面是因为稳定长期上下文权重应高于临时分析数据
                if HoloAIFeatureFlags.profileAnalysisInjectionEnabled,
                   let snapshot = userContext.profileSnapshot,
                   !snapshot.isEmpty {
                    let profilePrompt = HoloProfilePromptRenderer.render(snapshot, purpose: .analysis)
                    if !profilePrompt.isEmpty {
                        allMessages.append(.system(profilePrompt))
                    }
                }
                allMessages.append(.system(contextOverride))
            } else {
                // 普通模式：注入用户即时上下文
                let contextMessage = AIUserContextMessageBuilder.build(from: userContext, purpose: .chat)
                allMessages.append(.system(contextMessage))
            }

            // 分析模式下 messages 为空（零历史），普通模式携带历史
            allMessages.append(contentsOf: messages)

            let request = buildRequest(
                messages: allMessages,
                stream: true,
                temperature: systemContextOverride != nil ? 0.3 : nil
            )

            lastCallLog = LLMCallLog(
                type: "chat",
                model: config.model,
                requestMessages: allMessages,
                responseText: ""
            )

            return apiClient.sendStreaming(request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    // MARK: - Private Helpers

    private func buildRequest(messages: [ChatMessageDTO], stream: Bool = false, temperature: Double? = nil, responseFormat: ResponseFormat? = nil) -> APIRequest {
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
                temperature: temperature ?? config.temperature,
                maxTokens: config.maxTokens,
                stream: stream,
                responseFormat: responseFormat
            )
        )
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
            logger.error("ParsedResult JSON 解析失败，降级为普通聊天")
            logger.error("LLM 原始返回：\(text)")
            logger.error("提取的 JSON：\(jsonString)")
            logger.error("解析错误：\(error)")
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

    /// 从 AI 返回的 JSON 文本中解析 AIParseBatch
    /// 回退链：batch -> single ParsedResult -> clarification
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

        // 优先尝试 batch 格式
        if let batch = try? JSONDecoder().decode(AIParseBatch.self, from: data) {
            return batch
        }

        // 回退到单意图格式
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

        logger.error("Batch JSON 解析全部失败，回退为 clarification")
        logger.error("LLM 原始返回：\(text)")

        return AIParseBatch(
            mode: .clarification,
            items: [],
            needsClarification: true,
            clarificationQuestion: "我没完全理解这句话，你可以拆开再说一次吗？",
            fallbackResponseText: text
        )
    }

    private func parseActionBatchFromJSON(_ text: String, kind: AIActionParserKind) -> AIParseBatch {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            return actionClarification(fallbackText: text)
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

        guard let fields = Self.decodeActionFields(from: data) else {
            logger.error("结构化执行 JSON 解析失败，回退为 clarification")
            logger.error("LLM 原始返回：\(text)")
            return actionClarification(fallbackText: text)
        }

        if fields["needsClarification"] == "true" {
            return actionClarification(
                question: fields["unsupportedReason"] ?? fields["clarificationQuestion"],
                fallbackText: text
            )
        }

        let item = AIParseItem(
            intent: kind.defaultIntent,
            confidence: 0.95,
            extractedData: fields
        )
        return AIParseBatch(mode: .singleAction, items: [item])
    }

    private func actionClarification(question: String? = nil, fallbackText: String) -> AIParseBatch {
        AIParseBatch(
            mode: .clarification,
            items: [],
            needsClarification: true,
            clarificationQuestion: question ?? "这个结构化操作暂不支持，请换一种说法或拆开处理。",
            fallbackResponseText: fallbackText
        )
    }

    private static func decodeActionFields(from data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var fields: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case is NSNull:
                continue
            case let string as String:
                fields[key] = string
            case let bool as Bool:
                fields[key] = bool ? "true" : "false"
            case let number as NSNumber:
                fields[key] = number.stringValue
            default:
                fields[key] = String(describing: value)
            }
        }
        return fields.isEmpty ? nil : fields
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
