//
//  HoloAgentLLMClient.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 3.4 agent_loop LLM 调用客户端
//  非流式调用后端 agent_loop purpose，返回原始文本交由 HoloAgentResponseParser 解析。
//  3.5 多轮 loop 通过 HoloAgentLLMClientProtocol 注入 fake client 做集成测试。
//

import Foundation

/// 真实 Agent LLM 客户端：走后端网关的 agent_loop purpose，非流式。
actor HoloAgentLLMClient: HoloAgentLLMClientProtocol {

    private let provider: HoloBackendAIProvider

    init(provider: HoloBackendAIProvider) {
        self.provider = provider
    }

    func next(messages: [HoloAgentMessage]) async throws -> String {
        let chatMessages = messages.map {
            ChatMessageDTO(role: $0.role.rawValue, content: $0.content)
        }
        // purpose=.agentLoop 走后端 agent_loop route，返回内容由后端做 JSON 校验
        return try await provider.chat(messages: chatMessages, purpose: .agentLoop)
    }
}
