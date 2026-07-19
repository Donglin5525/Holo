//
//  HoloAgentLLMClient.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 3.4 agent_loop LLM 调用客户端
//  非流式调用后端 agent_loop purpose，返回原始文本交由 HoloAgentResponseParser 解析。
//  3.5 多轮 loop 通过 HoloAgentLLMClientProtocol 注入 fake client 做集成测试。
//
//  Holo Agent 稳定执行 — Phase 4（§8.1/8.3，修 P0-7）
//  - step 幂等：携带 runId/stepId/requestHash，后端按 `runId + stepId` 幂等
//  - 重试归并：删除本层「任何错误睡 2s 整体重试」，HTTP 重试唯一归 APIClient；
//    STEP_IN_PROGRESS 退避由 APIClient 按幂等协议处理，不做重试乘法
//

import Foundation

/// 真实 Agent LLM 客户端：走后端网关的 agent_loop purpose，非流式。
actor HoloAgentLLMClient: HoloAgentLLMClientProtocol {

    private let provider: HoloBackendAIProvider

    init(provider: HoloBackendAIProvider) {
        self.provider = provider
    }

    func next(messages: [HoloAgentMessage]) async throws -> String {
        try await next(messages: messages, step: nil)
    }

    func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String {
        let chatMessages = messages.map {
            let apiRole: String
            let content: String
            switch $0.role {
            case .toolResult:
                apiRole = "assistant"
                content = "工具执行结果：\n\($0.content)"
            default:
                apiRole = $0.role.rawValue
                content = $0.content
            }
            return ChatMessageDTO(role: apiRole, content: content)
        }
        // purpose=.agentLoop 走后端 agent_loop route；step 非 nil 时按 §8.1 幂等。
        // Phase 4 任务5：本层不再整体重试（原「任何错误睡 2s 重试一次」已删除），
        // 避免与 APIClient 的 HTTP 重试叠加成重试乘法。
        return try await provider.chat(messages: chatMessages, purpose: .agentLoop, step: step)
    }
}
