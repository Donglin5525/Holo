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
}
