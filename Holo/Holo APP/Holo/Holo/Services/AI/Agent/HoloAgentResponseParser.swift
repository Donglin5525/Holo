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
    ///
    /// P0-D 集成：解析后经 HoloAgentContractPolicy 校验。
    /// 兼容修复（补默认值）仍保留以维持 decode 成功，但关键违规（空 final_claims、
    /// 事实 claim 无 evidence、confidence 越界、空 displayText）会按当前模式决定是否拒绝。
    /// Debug 构建下任何违规都抛错；生产仅关键违规拒绝。
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
            if let warnings = json["warnings"] as? [Any] {
                json["warnings"] = warnings.compactMap(Self.stringValue)
            }
            if var claims = json["claims"] as? [[String: Any]] {
                for i in 0..<claims.count {
                    if claims[i]["id"] == nil { claims[i]["id"] = "claim-\(i + 1)" }
                    if claims[i]["displayText"] == nil, let text = claims[i]["text"] as? String {
                        claims[i]["displayText"] = text
                    }
                    if claims[i]["metricAssertions"] == nil { claims[i]["metricAssertions"] = [] }
                    if claims[i]["evidenceIDs"] == nil, let evidenceIds = claims[i]["evidenceIds"] {
                        claims[i]["evidenceIDs"] = evidenceIds
                    }
                    if claims[i]["evidenceIDs"] == nil { claims[i]["evidenceIDs"] = [] }
                    if claims[i]["prohibitedInferences"] == nil { claims[i]["prohibitedInferences"] = [] }
                    claims[i]["evidenceIDs"] = Self.stringArray(from: claims[i]["evidenceIDs"])
                    claims[i]["prohibitedInferences"] = Self.stringArray(from: claims[i]["prohibitedInferences"])
                    claims[i]["confidence"] = Self.doubleValue(claims[i]["confidence"]) ?? 0.5
                    if claims[i]["type"] == nil { claims[i]["type"] = "observation" }
                    if var metricAssertions = claims[i]["metricAssertions"] as? [[String: Any]] {
                        for j in 0..<metricAssertions.count {
                            if metricAssertions[j]["evidenceIDs"] == nil,
                               let evidenceIds = metricAssertions[j]["evidenceIds"] {
                                metricAssertions[j]["evidenceIDs"] = evidenceIds
                            }
                            metricAssertions[j]["evidenceIDs"] = Self.stringArray(
                                from: metricAssertions[j]["evidenceIDs"]
                            )
                            if let value = Self.doubleValue(metricAssertions[j]["value"]) {
                                metricAssertions[j]["value"] = value
                            }
                            if let value = Self.doubleValue(metricAssertions[j]["baselineValue"]) {
                                metricAssertions[j]["baselineValue"] = value
                            }
                        }
                        claims[i]["metricAssertions"] = metricAssertions
                    }
                }
                json["claims"] = claims
            }
            if var requests = json["toolRequests"] as? [[String: Any]] {
                for i in 0..<requests.count {
                    // 生产事故兼容：早期后端 Prompt 的输出 schema 只展示 parameters，
                    // 模型会把 dynamicPlan/crossDomainPlan 塞进 parameters，导致
                    // [String: String] 解码整轮失败。计划字段必须提升为 toolRequest 同级字段。
                    Self.promoteNestedPlans(in: &requests[i])
                    requests[i]["requiredMetrics"] = Self.stringArray(from: requests[i]["requiredMetrics"])
                    requests[i]["parameters"] = Self.stringParameters(from: requests[i]["parameters"])
                    Self.normalizeTimeRange(in: &requests[i], key: "timeRange")
                    Self.normalizeTimeRange(in: &requests[i], key: "baseline")
                    if var plan = requests[i]["dynamicPlan"] as? [String: Any] {
                        Self.normalizeTimeRange(in: &plan, key: "timeRange")
                        Self.normalizeTimeRange(in: &plan, key: "baseline")
                        if plan["filters"] == nil { plan["filters"] = [] }
                        if plan["groupBy"] == nil { plan["groupBy"] = [] }
                        if plan["derivations"] == nil { plan["derivations"] = [] }
                        if plan["sort"] == nil { plan["sort"] = NSNull() }
                        plan["limit"] = Self.intValue(plan["limit"]) ?? 20
                        plan["evidenceLimit"] = Self.intValue(plan["evidenceLimit"]) ?? 20
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
                        if let threshold = Self.doubleValue(plan["threshold"]) {
                            plan["threshold"] = threshold
                        } else {
                            plan["threshold"] = NSNull()
                        }
                        plan["minimumAlignedDays"] = Self.intValue(plan["minimumAlignedDays"]) ?? 5
                        Self.normalizeTimeRange(in: &plan, key: "timeRange")
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
                return try Self.applyContractPolicy(output, remainingRetries: remainingRetries)
            }
        }

        // 回退：原始 data 直接 decode
        if let output = try? JSONDecoder().decode(HoloAgentOutput.self, from: data) {
            return try Self.applyContractPolicy(output, remainingRetries: remainingRetries)
        }

        throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
    }

    /// P0-D：解析成功后应用契约策略。
    /// - Debug：任何违规（含兼容字段缺失）都失败，便于及早发现协议退化。
    /// - 生产：仅关键违规（空 final_claims / 事实 claim 无 evidence / confidence 越界 / 空 displayText）拒绝。
    /// 被拒绝时按剩余重试次数决定是否允许重试。
    /// 违规和修复计数通过 HoloAgentContractViolationCounter 记录，供 telemetry 读取。
    private static func applyContractPolicy(_ output: HoloAgentOutput, remainingRetries: Int) throws -> HoloAgentOutput {
        let contractResult = HoloAgentContractPolicy.validate(output: output)
        // P0-D：记录非敏感指标（违规/修复计数），供 Runtime telemetry 读取
        if contractResult.hasViolations || !contractResult.repairs.isEmpty {
            HoloAgentContractViolationCounter.shared.record(
                violations: contractResult.violations.count,
                repairs: contractResult.repairs.count
            )
        }
        if contractResult.isRejected {
            // 关键违规：不静默放过，按剩余重试次数决定是否可重试。
            throw HoloAgentError.outputParseFailure(needsRetry: remainingRetries > 0)
        }
        return output
    }

    private static func promoteNestedPlans(in request: inout [String: Any]) {
        guard var parameters = request["parameters"] as? [String: Any] else {
            if request["parameters"] == nil { request["parameters"] = [:] }
            return
        }
        for key in ["dynamicPlan", "crossDomainPlan"] {
            let current = request[key]
            let isMissing = current == nil || current is NSNull
            if isMissing, let nested = parameters[key] as? [String: Any] {
                request[key] = nested
            }
            parameters.removeValue(forKey: key)
        }
        request["parameters"] = parameters
    }

    private static func normalizeTimeRange(in object: inout [String: Any], key: String) {
        guard var range = object[key] as? [String: Any] else {
            object[key] = NSNull()
            return
        }
        guard let label = range["label"] as? String else {
            object[key] = NSNull()
            return
        }
        // 只有 JSONDecoder 可直接解码的数值时间戳才接受模型窗口。
        // ISO 字符串、空边界或仅有 label 的窗口一律丢弃，让 runtime 使用问题解析出的确定性 job 窗口，
        // 避免“本月”这种空壳范围阻止 requestWithJobScope 注入真实 start/end。
        guard range["start"] is NSNumber, range["end"] is NSNumber else {
            object[key] = NSNull()
            return
        }
        range["label"] = label
        object[key] = range
    }

    private static func stringParameters(from value: Any?) -> [String: String] {
        guard let parameters = value as? [String: Any] else { return [:] }
        return parameters.reduce(into: [:]) { result, entry in
            if let string = stringValue(entry.value) {
                result[entry.key] = string
            } else if JSONSerialization.isValidJSONObject(entry.value),
                      let data = try? JSONSerialization.data(withJSONObject: entry.value),
                      let string = String(data: data, encoding: .utf8) {
                result[entry.key] = string
            }
        }
    }

    private static func stringArray(from value: Any?) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap(stringValue)
        }
        if let single = stringValue(value) {
            return [single]
        }
        return []
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
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
