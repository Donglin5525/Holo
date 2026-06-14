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
}
