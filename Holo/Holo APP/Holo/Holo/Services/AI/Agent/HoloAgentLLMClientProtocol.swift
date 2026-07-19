//
//  HoloAgentLLMClientProtocol.swift
//  Holo
//
//  HoloAI Agent V3.1 — Agent LLM 客户端协议
//  runtime 依赖此协议；生产实现 HoloAgentLLMClient（依赖后端 provider）在独立文件，
//  本协议文件不引入重依赖，便于 standalone 测试注入 fake client。
//

import Foundation

/// Agent LLM 客户端协议。
protocol HoloAgentLLMClientProtocol: Sendable {
    /// 发送一轮消息，返回 LLM 原始文本（应为 JSON）。
    func next(messages: [HoloAgentMessage]) async throws -> String

    /// 带 step 幂等标识的一轮请求（§5.3/§8.1）：非 nil 时携带 runId/stepId/requestHash，
    /// 后端按 `runId + stepId` 幂等返回同一响应；nil 走旧无幂等路径。
    func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String
}

extension HoloAgentLLMClientProtocol {
    /// 默认实现转发旧方法：已有 fake/调用方零适配。
    func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String {
        try await next(messages: messages)
    }
}
