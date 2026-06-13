//
//  HoloAgentPromptBuilder.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 3.4 agent_loop Prompt 构造
//  组装 system（模板 + 工具描述 + 脱敏证据）+ conversationState + 用户问题为消息序列。
//  只注入 redactedExcerpt，绝不把完整 excerpt（可能含敏感原文）发给 LLM。
//

import Foundation

enum HoloAgentPromptBuilder {

    /// 构造一轮 agent_loop 的消息序列。
    static func build(
        systemTemplate: String,
        toolDescriptions: String,
        evidence: [HoloEvidenceRecord],
        conversationState: [HoloAgentMessage],
        userQuestion: String
    ) -> [HoloAgentMessage] {
        var system = systemTemplate
        if !toolDescriptions.isEmpty {
            system += "\n\n可用工具：\n\(toolDescriptions)"
        }
        if !evidence.isEmpty {
            // 只注入脱敏摘要，完整 excerpt 仅本地 Verifier 使用
            let lines = evidence
                .map { "- \($0.redactedExcerpt)" }
                .joined(separator: "\n")
            system += "\n\n已有证据（脱敏，勿引用完整原文）：\n\(lines)"
        }

        var messages: [HoloAgentMessage] = [
            HoloAgentMessage(role: .system, content: system, toolRequestID: nil, toolName: nil,
                             timestamp: Date(timeIntervalSince1970: 0), tokenEstimate: nil)
        ]
        messages.append(contentsOf: conversationState)
        messages.append(
            HoloAgentMessage(role: .user, content: userQuestion, toolRequestID: nil, toolName: nil,
                             timestamp: Date(timeIntervalSince1970: 0), tokenEstimate: nil)
        )
        return messages
    }
}
