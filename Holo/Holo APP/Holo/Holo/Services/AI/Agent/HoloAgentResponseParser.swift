//
//  HoloAgentResponseParser.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 3.4 agent_loop LLM 输出解析
//  剥离 markdown code block，解析为 HoloAgentOutput；失败按剩余重试次数决定是否可重试。
//

import Foundation

/// Agent 运行时错误。
enum HoloAgentError: Error, Equatable {
    /// LLM 输出无法解析为合法 HoloAgentOutput；needsRetry 控制是否还允许重试。
    case outputParseFailure(needsRetry: Bool)
    /// 预算（轮数/token/时间）耗尽。
    case budgetExhausted
    /// 任务被取消。
    case cancelled
}

enum HoloAgentResponseParser {

    /// 解析 LLM 原始输出。
    /// - Parameters:
    ///   - raw: LLM 返回的原始文本（可能含 ```json 包裹）。
    ///   - remainingRetries: 剩余可重试次数；为 0 时 needsRetry 返回 false。
    /// - Returns: 解析出的 HoloAgentOutput。
    static func parse(_ raw: String, remainingRetries: Int) throws -> HoloAgentOutput {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let output = try? JSONDecoder().decode(HoloAgentOutput.self, from: data) else {
            throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
        }
        return output
    }
}
