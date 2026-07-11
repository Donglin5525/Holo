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
        let cleaned = extractJSONObject(from: raw)

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
                    if claims[i]["displayText"] == nil, let text = claims[i]["text"] as? String {
                        claims[i]["displayText"] = text
                    }
                    if claims[i]["metricAssertions"] == nil { claims[i]["metricAssertions"] = [] }
                    if claims[i]["evidenceIDs"] == nil, let evidenceIds = claims[i]["evidenceIds"] {
                        claims[i]["evidenceIDs"] = evidenceIds
                    }
                    if claims[i]["evidenceIDs"] == nil { claims[i]["evidenceIDs"] = [] }
                    if claims[i]["prohibitedInferences"] == nil { claims[i]["prohibitedInferences"] = [] }
                    if claims[i]["confidence"] == nil { claims[i]["confidence"] = 0.5 }
                    if claims[i]["type"] == nil { claims[i]["type"] = "observation" }
                    if var metricAssertions = claims[i]["metricAssertions"] as? [[String: Any]] {
                        for j in 0..<metricAssertions.count {
                            if metricAssertions[j]["evidenceIDs"] == nil,
                               let evidenceIds = metricAssertions[j]["evidenceIds"] {
                                metricAssertions[j]["evidenceIDs"] = evidenceIds
                            }
                            if metricAssertions[j]["evidenceIDs"] == nil {
                                metricAssertions[j]["evidenceIDs"] = []
                            }
                        }
                        claims[i]["metricAssertions"] = metricAssertions
                    }
                }
                json["claims"] = claims
            }
            if var requests = json["toolRequests"] as? [[String: Any]] {
                for i in 0..<requests.count {
                    if requests[i]["requiredMetrics"] == nil { requests[i]["requiredMetrics"] = [] }
                    if requests[i]["parameters"] == nil { requests[i]["parameters"] = [:] }
                    if var plan = requests[i]["dynamicPlan"] as? [String: Any] {
                        if plan["timeRange"] == nil { plan["timeRange"] = NSNull() }
                        if plan["baseline"] == nil { plan["baseline"] = NSNull() }
                        if plan["filters"] == nil { plan["filters"] = [] }
                        if plan["groupBy"] == nil { plan["groupBy"] = [] }
                        if plan["derivations"] == nil { plan["derivations"] = [] }
                        if plan["sort"] == nil { plan["sort"] = NSNull() }
                        if plan["limit"] == nil { plan["limit"] = 20 }
                        if plan["evidenceLimit"] == nil { plan["evidenceLimit"] = 20 }
                        if var filters = plan["filters"] as? [[String: Any]] {
                            for index in filters.indices where filters[index]["values"] == nil { filters[index]["values"] = [] }
                            plan["filters"] = filters
                        }
                        if var groupings = plan["groupBy"] as? [[String: Any]] {
                            for index in groupings.indices where groupings[index]["field"] == nil { groupings[index]["field"] = NSNull() }
                            plan["groupBy"] = groupings
                        }
                        if var aggregations = plan["aggregations"] as? [[String: Any]] {
                            for index in aggregations.indices {
                                if aggregations[index]["field"] == nil { aggregations[index]["field"] = NSNull() }
                                if aggregations[index]["unit"] == nil { aggregations[index]["unit"] = NSNull() }
                                if aggregations[index]["filters"] == nil { aggregations[index]["filters"] = [] }
                            }
                            plan["aggregations"] = aggregations
                        }
                        if var derivations = plan["derivations"] as? [[String: Any]] {
                            for index in derivations.indices {
                                if derivations[index]["denominatorMetricID"] == nil { derivations[index]["denominatorMetricID"] = NSNull() }
                                if derivations[index]["unit"] == nil { derivations[index]["unit"] = NSNull() }
                            }
                            plan["derivations"] = derivations
                        }
                        requests[i]["dynamicPlan"] = plan
                    }
                    if var plan = requests[i]["crossDomainPlan"] as? [String: Any] {
                        if plan["leftFilters"] == nil { plan["leftFilters"] = [] }
                        if plan["rightFilters"] == nil { plan["rightFilters"] = [] }
                        if plan["threshold"] == nil { plan["threshold"] = NSNull() }
                        if plan["minimumAlignedDays"] == nil { plan["minimumAlignedDays"] = 5 }
                        if plan["timeRange"] == nil { plan["timeRange"] = NSNull() }
                        for key in ["leftFilters", "rightFilters"] {
                            if var filters = plan[key] as? [[String: Any]] {
                                for index in filters.indices where filters[index]["values"] == nil { filters[index]["values"] = [] }
                                plan[key] = filters
                            }
                        }
                        requests[i]["crossDomainPlan"] = plan
                    }
                }
                json["toolRequests"] = requests
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

    private static func extractJSONObject(from raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{") else {
            return cleaned
        }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < cleaned.endIndex {
            let character = cleaned[index]

            if escaped {
                escaped = false
                index = cleaned.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = cleaned.index(after: index)
                continue
            }
            if character == "\"" {
                inString.toggle()
                index = cleaned.index(after: index)
                continue
            }
            if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(cleaned[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }

            index = cleaned.index(after: index)
        }

        return cleaned
    }
}
