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

        guard let data = cleaned.data(using: .utf8) else {
            throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
        }

        // 容错：补全 deepseek 可能省略的空数组/默认值字段
        if var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if json["toolRequests"] == nil { json["toolRequests"] = [] }
            if json["claims"] == nil { json["claims"] = [] }
            if json["warnings"] == nil { json["warnings"] = [] }
            if json["reasoning"] == nil { json["reasoning"] = "" }
            if var claims = json["claims"] as? [[String: Any]] {
                for i in 0..<claims.count {
                    if claims[i]["metricAssertions"] == nil { claims[i]["metricAssertions"] = [] }
                    if claims[i]["evidenceIDs"] == nil { claims[i]["evidenceIDs"] = [] }
                    if claims[i]["prohibitedInferences"] == nil { claims[i]["prohibitedInferences"] = [] }
                    if claims[i]["confidence"] == nil { claims[i]["confidence"] = 0.5 }
                    if claims[i]["type"] == nil { claims[i]["type"] = "observation" }
                }
                json["claims"] = claims
            }
            if let fixedData = try? JSONSerialization.data(withJSONObject: json),
               let output = try? JSONDecoder().decode(HoloAgentOutput.self, from: fixedData) {
                return output
            }
        }

        // 回退：原始 data 直接 decode
        if let output = try? JSONDecoder().decode(HoloAgentOutput.self, from: data) {
            return output
        }

        throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
    }
}
