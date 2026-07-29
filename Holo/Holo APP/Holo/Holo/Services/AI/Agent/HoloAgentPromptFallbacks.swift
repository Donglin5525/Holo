//
//  HoloAgentPromptFallbacks.swift
//  Holo
//
//  Release 配置下 Agent systemTemplate 的安全占位。
//
//  当后端 prompt 拉取失败时，Release 不能内嵌完整商业 Prompt 正文，
//  但需要一个非空字符串保证 HoloAgentPromptBuilder 的消息结构完整，
//  并提供最小协议约束。
//
//  正常链路下，后端 injectServerPrompt 会在客户端 messages 前插入完整的权威
//  system prompt（人格层 + agentLoop 正文 + contract appendix）。
//  因此这份占位只是"消息结构兜底"，不会成为模型实际遵循的唯一指令。
//

import Foundation

/// Release 下 Agent systemTemplate 的安全占位。全配置可见，不含商业 Prompt 正文。
enum HoloAgentPromptFallbacks {

    /// agent_loop 的安全占位。最小协议提示，不含商业逻辑。
    /// 真正的 system prompt 由后端 injectServerPrompt 注入。
    static let agentLoopSafePlaceholder: String = """
    你是 HoloAI 的 Agent 推理器。你只能输出 JSON。
    当后端 system prompt 可用时，以后者为准。
    """
}
