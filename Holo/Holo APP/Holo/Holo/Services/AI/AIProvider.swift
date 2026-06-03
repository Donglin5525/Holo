//
//  AIProvider.swift
//  Holo
//
//  AI Provider 协议定义
//  统一的 AI 服务接口
//

import Foundation

/// 记忆洞察生成结果（包含原始响应和 Prompt 版本信息）
struct MemoryInsightGenerationResult: Sendable {
    let rawResponse: String
    let promptType: String
    let promptVersion: Int?
}

/// AI 服务提供者协议
protocol AIProvider {
    /// 最近一次 LLM 调用的日志（请求+响应），由 Provider 在每次调用后更新
    var lastCallLog: LLMCallLog? { get }

    /// 解析用户输入（意图识别 + 数据提取）
    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult

    /// 非流式对话
    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String

    /// 流式对话
    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error>

    /// 流式对话（扩展参数，支持分析模式）
    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error>

    /// 批量解析用户输入（多动作支持）
    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch

    /// 结构化执行参数解析（分期记账/重复任务）
    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch

    /// 生成记忆洞察（自定义 prompt + 结构化 context JSON）
    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult
}

/// 结构化执行解析类型
enum AIActionParserKind: Sendable {
    case financeInstallment
    case taskRepeat

    var promptType: PromptManager.PromptType {
        switch self {
        case .financeInstallment: return .financeActionParser
        case .taskRepeat: return .taskActionParser
        }
    }
}

extension AIProvider {
    /// 便捷方法：不带分析参数的流式对话（向后兼容）
    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext
    ) -> AsyncThrowingStream<String, Error> {
        chatStreaming(
            messages: messages,
            userContext: userContext,
            systemContextOverride: nil,
            promptType: .systemPrompt
        )
    }

    /// 默认实现：不支持记忆洞察
    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult {
        throw APIError.serverError("当前 Provider 不支持记忆洞察生成")
    }

    /// 默认实现：不支持结构化执行解析
    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch {
        throw APIError.serverError("当前 Provider 不支持结构化执行解析")
    }

    /// 非流式目标规划调用
    func completeGoalPlanning(prompt: String, context: UserContext) async throws -> String {
        let messages = [
            ChatMessageDTO(role: "user", content: prompt)
        ]
        var text = ""
        for try await chunk in chatStreaming(messages: messages, userContext: context) {
            text += chunk
        }
        return text
    }

    /// 默认实现：将单意图结果包装为 batch
    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
        let single = try await parseUserInput(input, context: context)

        let mode: AIInteractionMode
        switch single.intent {
        case _ where single.intent.isQuery:
            mode = .query
        case .unknown:
            mode = single.needsClarification ? .clarification : .unknown
        default:
            mode = .singleAction
        }

        return AIParseBatch(
            mode: mode,
            items: [single.asParseItem],
            needsClarification: single.needsClarification,
            clarificationQuestion: single.clarificationQuestion,
            fallbackResponseText: single.responseText
        )
    }
}
