//
//  AIProvider.swift
//  Holo
//
//  AI Provider 协议定义
//  统一的 AI 服务接口
//

import Foundation

/// AI 服务提供者协议
protocol AIProvider {
    /// 解析用户输入（意图识别 + 数据提取）
    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult

    /// 生成洞察/总结
    func generateInsight(type: InsightType, data: UserContext) async throws -> String

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

    /// 生成记忆洞察（自定义 prompt + 结构化 context JSON）
    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> String
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
    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> String {
        throw APIError.serverError("当前 Provider 不支持记忆洞察生成")
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
