//
//  LLMCallLog.swift
//  Holo
//
//  大模型调用日志模型
//  记录每次 LLM 调用的请求和响应，用于调试
//

import Foundation

/// 单次 LLM 调用日志
nonisolated struct LLMCallLog: Codable, Equatable {
    /// 调用类型："intent_recognition" | "chat"
    let type: String
    /// 使用的模型名称
    let model: String
    /// 发送给 LLM 的完整消息数组
    let requestMessages: [ChatMessageDTO]
    /// LLM 返回的原始文本（流式场景由 ViewModel 后填）
    var responseText: String
}

/// 一次用户交互的完整日志（可能包含多次 LLM 调用）
nonisolated struct LLMLog: Codable, Equatable {
    let calls: [LLMCallLog]
}
