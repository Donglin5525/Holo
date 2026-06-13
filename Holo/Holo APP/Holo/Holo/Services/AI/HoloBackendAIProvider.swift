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
        promptService: HoloBackendPromptService? = nil
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
        self.promptService = promptService ?? .shared
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
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
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

    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch {
        let systemPrompt = await loadManagedPrompt(kind.promptType)
        let messages: [ChatMessageDTO] = [
            .system(systemPrompt),
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
            .user(input)
        ]

        let request = buildRequest(
            purpose: kind.backendPurpose,
            messages: messages,
            responseFormat: .jsonObject
        )
        let response: ChatCompletionResponse = try await apiClient.send(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            type: kind.promptType.rawValue,
            model: "holo-backend",
            requestMessages: messages,
            responseText: content
        )

        return parseActionBatchFromJSON(content, kind: kind)
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
                    // 分析模式：先注入 profile（如开启），再注入分析 context JSON
                    if HoloAIFeatureFlags.profileAnalysisInjectionEnabled,
                       let snapshot = userContext.profileSnapshot,
                       !snapshot.isEmpty {
                        let profilePrompt = HoloProfilePromptRenderer.render(snapshot, purpose: .analysis)
                        if !profilePrompt.isEmpty {
                            allMessages.append(.system(profilePrompt))
                        }
                    }
                    allMessages.append(.system(systemContextOverride))
                } else {
                    allMessages.append(.system(AIUserContextMessageBuilder.build(
                        from: userContext,
                        purpose: .chat,
                        userText: Self.latestUserText(in: messages)
                    )))
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
            .system(AIUserContextMessageBuilder.build(
                from: userContext,
                purpose: .chat,
                userText: Self.latestUserText(in: messages)
            ))
        ]
        allMessages.append(contentsOf: messages)
        return allMessages
    }

    private static func latestUserText(in messages: [ChatMessageDTO]) -> String? {
        messages.last(where: { $0.role == "user" })?.content
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
    case memoryObserver = "memory_observer"
    case financeActionParser = "finance_action_parser"
    case taskActionParser = "task_action_parser"
    case thoughtOrganization = "thought_organization"
    case agentLoop = "agent_loop"
}

extension AIActionParserKind {
    var backendPurpose: HoloBackendPurpose {
        switch self {
        case .financeInstallment: return .financeActionParser
        case .taskRepeat: return .taskActionParser
        }
    }
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

nonisolated final class HoloBackendDeviceIdentity {
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
