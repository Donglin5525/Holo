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
    private(set) var lastCallLog: LLMCallLog?

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
    }

    // MARK: - AIProvider

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        try ensureDataProcessingConsent()
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
        try ensureDataProcessingConsent()
        let messages: [ChatMessageDTO] = [
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
            .user(input)
        ]

        let request = buildRequest(
            purpose: .intent,
            messages: messages,
            responseFormat: .jsonObject
        )
        let (response, requestId) = try await sendCompletion(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            requestId: requestId,
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
        try ensureDataProcessingConsent()
        let messages: [ChatMessageDTO] = [
            .system(AIUserContextMessageBuilder.build(from: context, purpose: .intentRecognition)),
            .user(input)
        ]

        let request = buildRequest(
            purpose: kind.backendPurpose,
            messages: messages,
            responseFormat: .jsonObject
        )
        let (response, requestId) = try await sendCompletion(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            requestId: requestId,
            type: kind.promptType.rawValue,
            model: "holo-backend",
            requestMessages: messages,
            responseText: content
        )

        return parseActionBatchFromJSON(content, kind: kind)
    }

    func generateHealthInsight(contextJSON: String) async throws -> HealthInsightGenerationResult {
        try ensureDataProcessingConsent()
        let messages: [ChatMessageDTO] = [
            .user(contextJSON)
        ]
        let request = buildRequest(purpose: .healthInsightGeneration, messages: messages, responseFormat: .jsonObject)
        let (response, _) = try await sendCompletion(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return HealthInsightGenerationResult(
            rawResponse: content,
            promptVersion: nil
        )
    }

    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult {
        try ensureDataProcessingConsent()
        let messages: [ChatMessageDTO] = [
            .user(contextJSON)
        ]
        // DeepSeek 推理模型不强制 json_object；服务端 Prompt + 校验器负责结构化约束。
        let request = buildRequest(purpose: .insight, messages: messages)
        let (response, requestId) = try await sendCompletion(request)

        guard let choice = response.choices?.first,
              choice.finishReason != "length",
              let content = choice.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        return MemoryInsightGenerationResult(
            rawResponse: content,
            promptType: "memory_insight_generation",
            promptVersion: nil,
            requestId: requestId
        )
    }

    /// 端到端流式生成记忆洞察。
    /// iOS stream=true → 后端 streamChat 透传 DeepSeek SSE → iOS 边收边 yield。
    /// 避免非流式长生成期间连接无数据，被移动网络 NAT 在 ~30s RST（导致 nginx 499 / iOS -1005）。
    func generateMemoryInsightStreaming(type: InsightType, contextJSON: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ensureDataProcessingConsent()
                    let messages: [ChatMessageDTO] = [.user(contextJSON)]
                    let request = buildRequest(purpose: .insight, messages: messages, stream: true)

                    for try await chunk in apiClient.sendStreaming(request) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    await HoloSubscriptionService.shared.refreshStatus()
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 消费端取消时传导给内部 Task，中断下层网络连接（同 chatStreaming）。
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        try ensureDataProcessingConsent()
        let allMessages = buildChatMessages(messages: messages, userContext: userContext)
        let request = buildRequest(purpose: .chat, messages: allMessages)
        let (response, requestId) = try await sendCompletion(request)

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }

        lastCallLog = LLMCallLog(
            requestId: requestId,
            type: "chat",
            model: "holo-backend",
            requestMessages: allMessages,
            responseText: content
        )

        return content
    }

    func completeFlexibleQueryPlan(prompt: String, userContext: UserContext) async throws -> String {
        try ensureDataProcessingConsent()
        let request = buildRequest(
            purpose: .flexibleQueryPlanner,
            messages: [.user(prompt)],
            responseFormat: .jsonObject
        )
        let (response, _) = try await sendCompletion(request)

        guard let content = response.choices?.first?.message?.content, !content.isEmpty else {
            throw APIError.serverError("AI 未返回有效查询计划")
        }
        return content
    }

    /// 每周计划组装：专用 purpose（JSON 模式 + 后端 none 推理档，实测 6-8s）
    func completeWeeklyPlan(prompt: String, context: UserContext) async throws -> String {
        try await chat(messages: [ChatMessageDTO(role: "user", content: prompt)], purpose: .weeklyPlanGeneration)
    }

    /// P2（方案 §5.3）：批量文本 embedding（/v1/ai/embeddings，purpose=thought_embedding）。
    /// 向量仅作客户端语义候选召回输入，不直接决定用户可见结果（V3 教训）。
    /// - Parameter texts: 1-16 条非空文本（每条 ≤2000 字符，由调用方保证）
    /// - Returns: 与 texts 等长、等维的向量数组
    func embed(texts: [String]) async throws -> [[Double]] {
        try ensureDataProcessingConsent()
        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/embeddings",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: HoloBackendEmbeddingsRequest(purpose: "thought_embedding", texts: texts)
        )
        let completion: APIClient.Response<HoloBackendEmbeddingsResponse> = try await apiClient.sendWithResponse(request)
        guard completion.value.vectors.count == texts.count else {
            throw APIError.serverError("Embedding 数量不匹配")
        }
        return completion.value.vectors
    }

    /// 使用自定义 purpose 的非流式 chat 调用（不注入 UserContext）。
    /// step 非 nil 且 purpose 为 agentLoop 时按 §8.1 携带 runId/stepId/requestHash（step 幂等）。
    func chat(messages: [ChatMessageDTO], purpose: HoloBackendPurpose,
              step: HoloAgentLLMRequestRecord? = nil) async throws -> String {
        try ensureDataProcessingConsent()
        let responseFormat: ResponseFormat? = (purpose == .agentLoop || purpose == .weeklyPlanGeneration) ? .jsonObject : nil
        let request = buildRequest(purpose: purpose, messages: messages, responseFormat: responseFormat, step: step)
        let completion: APIClient.Response<ChatCompletionResponse> = try await apiClient.sendWithResponse(request)
        let response = completion.value
        let requestId = completion.httpResponse.value(forHTTPHeaderField: "X-Holo-Request-Id")
        if completion.httpResponse.value(forHTTPHeaderField: "X-Holo-Quota-Type") != nil {
            await HoloSubscriptionService.shared.refreshStatus()
        }

        if completion.httpResponse.value(forHTTPHeaderField: "X-Holo-Step-Idempotency") == "hit",
           let step {
            var event = HoloAgentTelemetryEvent(
                name: .stepIdempotencyHit,
                requestID: step.stepID
            )
            event.jobID = step.runID
            await HoloAgentEventStore.shared.record(event)
        }

        guard let content = response.choices?.first?.message?.content else {
            throw APIError.serverError("AI 未返回有效内容")
        }


        lastCallLog = LLMCallLog(
            requestId: requestId,
            type: purpose.rawValue,
            model: "holo-backend",
            requestMessages: messages,
            responseText: content
        )

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
            let task = Task {
                do {
                    try ensureDataProcessingConsent()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var allMessages: [ChatMessageDTO] = []

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
                    purpose: promptType == .analysisPrompt ? .analysis : .chat,
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
                    for try await chunk in apiClient.sendStreaming(request, onResponse: { [weak self] response in
                        let requestId = response.value(forHTTPHeaderField: "X-Holo-Request-Id")
                        Task { @MainActor [weak self] in
                            self?.lastCallLog?.requestId = requestId
                        }
                    }) {
                        continuation.yield(chunk)
                    }
                    await HoloSubscriptionService.shared.refreshStatus()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 消费端取消迭代（用户点停止 → 上游 Task.cancel）时，把取消信号传导给
            // 内部 Task，让下层 sendStreaming 的网络连接真正中断（“表面取消”根治）。
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Building

    private func sendCompletion(_ request: APIRequest) async throws -> (ChatCompletionResponse, String?) {
        let result: APIClient.Response<ChatCompletionResponse> = try await apiClient.sendWithResponse(request)
        if result.httpResponse.value(forHTTPHeaderField: "X-Holo-Quota-Type") != nil {
            await HoloSubscriptionService.shared.refreshStatus()
        }
        return (
            result.value,
            result.httpResponse.value(forHTTPHeaderField: "X-Holo-Request-Id")
        )
    }

    private func ensureDataProcessingConsent() throws {
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            throw APIError.serverError(HoloAIDataProcessingConsent.requiredMessage)
        }
    }

    private func buildRequest(
        purpose: HoloBackendPurpose,
        messages: [ChatMessageDTO],
        stream: Bool = false,
        responseFormat: ResponseFormat? = nil,
        step: HoloAgentLLMRequestRecord? = nil
    ) -> APIRequest {
        // §8.1：step 三字段仅 agentLoop 携带；其他 purpose 保持兼容不编码
        let includeStep = purpose == .agentLoop ? step : nil
        return APIRequest(
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
                responseFormat: responseFormat,
                runId: includeStep?.runID,
                stepId: includeStep?.stepID,
                requestHash: includeStep?.requestHash,
                usageActionId: includeStep?.runID ?? UUID().uuidString
            )
        )
    }

    private func buildChatMessages(messages: [ChatMessageDTO], userContext: UserContext) -> [ChatMessageDTO] {
        var allMessages: [ChatMessageDTO] = [
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
    case analysis
    case intent
    case flexibleQueryPlanner = "flexible_query_planner"
    case insight
    case replayDigest = "replayDigest"
    case thoughtVoiceSummary = "thought_voice_summary"
    case memoryObserver = "memory_observer"
    case memoryDomainExtraction = "memory_domain_extraction"
    case memoryCrossDomainFusion = "memory_cross_domain_fusion"
    case financeActionParser = "finance_action_parser"
    case taskActionParser = "task_action_parser"
    case thoughtOrganization = "thought_organization"
    case thoughtTaskExtraction = "thought_task_extraction"
    case thoughtTagConvergence = "thought_tag_convergence"
    case categoryPatternInduction = "category_pattern_induction"
    case agentLoop = "agent_loop"
    case healthInsightGeneration = "health_insight_generation"
    case weeklyPlanGeneration = "weekly_plan_generation"
    // 账单智能导入（docs/plans/2026-08-17-finance-bill-import-ai-plan.md §5）
    case billColumnMapping = "bill_column_mapping"
    case billCategorization = "bill_categorization"
}

extension AIActionParserKind {
    var backendPurpose: HoloBackendPurpose {
        switch self {
        case .financeInstallment: return .financeActionParser
        case .taskRepeat: return .taskActionParser
        }
    }
}

// P2：批量 embedding 请求/响应（/v1/ai/embeddings）
struct HoloBackendEmbeddingsRequest: Encodable {
    let purpose: String
    let texts: [String]
}

struct HoloBackendEmbeddingsResponse: Decodable {
    let model: String
    let dimensions: Int
    let vectors: [[Double]]
}

struct HoloBackendChatCompletionRequest: Encodable {    let purpose: String
    let messages: [ChatMessageDTO]
    let stream: Bool
    let responseFormat: ResponseFormat?
    /// step 幂等三字段（§8.1）：仅 agentLoop 且 step 幂等开启时非空；
    /// 三者必须同时编码或同时缺失（后端部分缺失会 400，全缺完全兼容无幂等）。
    let runId: String?
    let stepId: String?
    let requestHash: String?
    let usageActionId: String

    enum CodingKeys: String, CodingKey {
        case purpose, messages, stream, runId, stepId, requestHash, usageActionId
        case responseFormat = "response_format"
    }

    init(purpose: String, messages: [ChatMessageDTO], stream: Bool,
         responseFormat: ResponseFormat?,
         runId: String? = nil, stepId: String? = nil, requestHash: String? = nil,
         usageActionId: String = UUID().uuidString) {
        self.purpose = purpose
        self.messages = messages
        self.stream = stream
        self.responseFormat = responseFormat
        self.runId = runId
        self.stepId = stepId
        self.requestHash = requestHash
        self.usageActionId = usageActionId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(purpose, forKey: .purpose)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encode(usageActionId, forKey: .usageActionId)
        if let runId, let stepId, let requestHash {
            try container.encode(runId, forKey: .runId)
            try container.encode(stepId, forKey: .stepId)
            try container.encode(requestHash, forKey: .requestHash)
        }
    }
}

nonisolated final class HoloBackendDeviceIdentity {
    static let shared = HoloBackendDeviceIdentity()

    private let key = "holo.backend.deviceId"
    private let userDefaults: UserDefaults
    /// iCloud 键值存储：卸载重装后 UserDefaults 清空，但 iCloud KVS 保留，
    /// AI 额度/订阅的设备归属不因重装而重置（后端 entitlement 按 deviceId 判定）
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    var deviceId: String {
        // 1) 本地缓存命中（含历史用户）
        if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
            syncToICloudIfNeeded(existing)
            return existing
        }
        // 2) iCloud 有（重装后恢复）
        if let restored = iCloudStore.string(forKey: key), !restored.isEmpty {
            userDefaults.set(restored, forKey: key)
            return restored
        }
        // 3) 全新设备：生成并双写
        let created = UUID().uuidString
        userDefaults.set(created, forKey: key)
        iCloudStore.set(created, forKey: key)
        return created
    }

    /// 历史 deviceId 尚未进 iCloud（未登录 iCloud 的用户 KVS 不可用，跳过静默）
    private func syncToICloudIfNeeded(_ deviceId: String) {
        guard iCloudStore.string(forKey: key) != deviceId else { return }
        iCloudStore.set(deviceId, forKey: key)
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
}
