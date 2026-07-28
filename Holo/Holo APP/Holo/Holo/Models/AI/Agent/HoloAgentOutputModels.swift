//
//  HoloAgentOutputModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — agent_loop 的 LLM JSON 输出协议
//

import Foundation

/// agent_loop 每一轮的状态：要工具 / 要继续推理 / 给出最终 claim
nonisolated enum HoloAgentOutputStatus: String, Codable, CaseIterable, Sendable {
    case needTools = "need_tools"
    case needMoreAnalysis = "need_more_analysis"
    case finalClaims = "final_claims"
}

/// claim 内的度量断言（Verifier 据此比对 evidence）
nonisolated struct HoloMetricAssertion: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var baselineValue: Double?
    var unit: String?
    var comparison: String?
    var evidenceIDs: [String]
}

/// Agent 的可信结论：必须挂 evidence、声明误用边界
nonisolated struct HoloAgentClaim: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var type: String
    var displayText: String
    var metricAssertions: [HoloMetricAssertion]
    var evidenceIDs: [String]
    var prohibitedInferences: [String]
    var confidence: Double
}

/// agent_loop 单轮 JSON 输出
nonisolated struct HoloAgentOutput: Codable, Equatable, Sendable {
    var status: HoloAgentOutputStatus
    var reasoning: String
    var toolRequests: [HoloToolRequest]
    var claims: [HoloAgentClaim]
    var nextStep: String?
    var warnings: [String]
    /// v17：final_claims 时 LLM 产出的一句话标题和自然摘要，用于有人味儿的呈现。
    /// need_tools/need_more_analysis 阶段为 nil。旧版本响应无此字段，decode 为 nil 兼容。
    var title: String?
    var narrativeSummary: String?
}

// MARK: - Answer fulfillment contract

/// 用户这一问明确要求 Agent 交付什么。它由本地确定性识别，不交给模型自行猜测，
/// 用于约束最终答案必须真正回答问题，而不是只堆砌查询到的数据。
nonisolated enum HoloAgentRequestedDeliverable: String, Codable, CaseIterable, Sendable {
    case directAnswer
    case diagnosis
    case recommendations
    case comparison
    case ranking
}

/// 最终答案完成度策略。这里仅判断交付物，不判断数值真假；
/// 数值与证据仍由 Claim Verifier 负责，两个门槛缺一不可。
nonisolated enum HoloAgentAnswerRequestPolicy {

    static func requestedDeliverables(for question: String) -> Set<HoloAgentRequestedDeliverable> {
        let normalized = question.lowercased()
        var deliverables: Set<HoloAgentRequestedDeliverable> = [.directAnswer]

        let diagnosisKeywords = [
            "分析", "问题", "风险", "异常", "原因", "为什么", "需要优化",
            "不合理", "值得注意", "有哪些地方", "表现怎么样"
        ]
        if diagnosisKeywords.contains(where: normalized.contains) {
            deliverables.insert(.diagnosis)
        }

        let recommendationKeywords = [
            "优化", "改进", "改善", "调整", "提升", "建议", "怎么办",
            "怎么做", "下一步", "如何做", "如何优化", "需要优化",
            "值得继续", "继续深化", "应该优先"
        ]
        if recommendationKeywords.contains(where: normalized.contains) {
            deliverables.insert(.recommendations)
        }

        let comparisonKeywords = ["比较", "对比", "相比", "环比", "同比", "变化", "较上"]
        if comparisonKeywords.contains(where: normalized.contains) {
            deliverables.insert(.comparison)
        }

        let rankingKeywords = ["最高", "最低", "最多", "最少", "排名", "主要", "重点", "优先"]
        if rankingKeywords.contains(where: normalized.contains) {
            deliverables.insert(.ranking)
        }
        return deliverables
    }

    static func requestsRecommendations(_ question: String?) -> Bool {
        guard let question else { return false }
        return requestedDeliverables(for: question).contains(.recommendations)
    }

    static func missingDeliverables(
        in claims: [HoloAgentClaim],
        question: String?
    ) -> Set<HoloAgentRequestedDeliverable> {
        guard let question else { return [] }
        let requested = requestedDeliverables(for: question)
        var missing: Set<HoloAgentRequestedDeliverable> = []

        if requested.contains(.directAnswer),
           !claims.contains(where: { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            missing.insert(.directAnswer)
        }
        if requested.contains(.recommendations),
           !claims.contains(where: { isRecommendationClaim($0) && HoloAgentClaimTextGroundingPolicy.unsupportedActionNumbers(in: $0).isEmpty }) {
            missing.insert(.recommendations)
        }
        if requested.contains(.diagnosis),
           !claims.contains(where: { isDiagnosticClaim($0) }) {
            missing.insert(.diagnosis)
        }
        return missing
    }

    static func isRecommendationClaim(_ claim: HoloAgentClaim) -> Bool {
        let normalizedType = claim.type.lowercased()
        return normalizedType == "suggestion"
            || normalizedType == "recommendation"
            || normalizedType == "action"
    }

    static func isDiagnosticClaim(_ claim: HoloAgentClaim) -> Bool {
        let normalizedType = claim.type.lowercased()
        return normalizedType == "observation"
            || normalizedType == "diagnosis"
            || normalizedType == "insight"
            || normalizedType == "comparison"
    }

    static func promptInstruction(
        question: String,
        authoritativeRange: HoloAgentTimeRange?
    ) -> String {
        let deliverables = requestedDeliverables(for: question)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        let rangeText: String
        if let authoritativeRange {
            rangeText = "\(authoritativeRange.label)；start=\(isoDate(authoritativeRange.start))；end(exclusive)=\(isoDate(authoritativeRange.end))"
        } else {
            rangeText = "用户未明确指定时间，按工具默认范围并在答案中明确披露"
        }
        return """
        [HOLO_AGENT_ANSWER_CONTRACT_V1]
        用户问题的确定性交付物：\(deliverables)。
        权威查询时间：\(rangeText)。
        - 权威查询时间来自用户原话，所有 toolRequest、dynamicPlan、crossDomainPlan 必须使用它，禁止自行缩成“近30天”等其他范围。
        - final_claims 必须先直接回答用户问题，再给最关键证据；不能只罗列指标。
        - 用户要求优化/改善/建议时，必须输出至少一条 type=suggestion 的可执行建议，并用已核验事实解释优先级。
        - suggestion 可以引用支撑诊断的 evidence；不得把相关性写成因果，不得编造预算、目标、金额阈值、节省金额、频次目标或医学结论。
        - 建议正文出现的任何金额、百分比、频次、天数或时长，都必须能由该 claim 的 metricAssertions 和 evidence 复算；没有对应证据时改成不带数字的具体动作。
        - 历史事实只统计 snapshotCutoffAt 之前已经发生的数据；未来计划、未来分期、未来任务不能混入已发生统计。
        """
    }

    private static func isoDate(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}

/// 模型的结构化 metricAssertion 通过校验，不代表 displayText 里夹带的额外数字也可信。
/// 对事实与建议中的金额、百分比、频次和周期目标做确定性反查：不在 assertion 当前值、
/// 基准值、指标定义常量或可复算差值/变化率中的数字，视为无证据数字。
nonisolated enum HoloAgentClaimTextGroundingPolicy {

    static func unsupportedActionNumbers(in claim: HoloAgentClaim) -> [Double] {
        guard HoloAgentAnswerRequestPolicy.isRecommendationClaim(claim) else { return [] }
        return unsupportedNumbers(in: claim)
    }

    static func unsupportedNumbers(
        in claim: HoloAgentClaim,
        evidence: [HoloEvidenceRecord] = []
    ) -> [Double] {
        let allowed = allowedValues(from: claim, evidence: evidence)
        let text = removingCalendarDates(from: claim.displayText)
        var candidates = numericCandidates(in: text)
        candidates.append(contentsOf: currencyPrefixedCandidates(in: text))

        var unsupported: [Double] = []
        for candidate in candidates where !allowed.contains(where: { approximatelyEqual(candidate, $0) }) {
            if !unsupported.contains(where: { approximatelyEqual(candidate, $0) }) {
                unsupported.append(candidate)
            }
        }
        return unsupported
    }

    private static func allowedValues(
        from claim: HoloAgentClaim,
        evidence: [HoloEvidenceRecord]
    ) -> [Double] {
        var values: [Double] = []
        var sourceValues: [Double] = []
        for assertion in claim.metricAssertions {
            values.append(contentsOf: semanticConstants(for: assertion.metricKey))
            if let value = assertion.value, value.isFinite {
                values.append(value)
                sourceValues.append(value)
                if abs(value) <= 1 { values.append(value * 100) }
            }
            if let baseline = assertion.baselineValue, baseline.isFinite {
                values.append(baseline)
                sourceValues.append(baseline)
                if abs(baseline) <= 1 { values.append(baseline * 100) }
            }
            if let value = assertion.value,
               let baseline = assertion.baselineValue,
               value.isFinite,
               baseline.isFinite {
                values.append(abs(value - baseline))
                if baseline != 0 {
                    values.append(abs((value - baseline) / baseline * 100))
                    values.append(abs(value / baseline))
                }
            }
        }
        let citedEvidenceIDs = Set(claim.evidenceIDs + claim.metricAssertions.flatMap(\.evidenceIDs))
        for record in evidence where citedEvidenceIDs.contains(record.id) {
            if let value = record.metricValue, value.isFinite {
                values.append(value)
                sourceValues.append(value)
            }
            if let baseline = record.baselineValue, baseline.isFinite {
                values.append(baseline)
                sourceValues.append(baseline)
            }
            // 交易样例等证据可能没有聚合 metricValue，但 excerpt 是本地工具生成的
            // 可核对事实。仅允许逐字出现在被该 claim 引用的 evidence 中的数字。
            for excerpt in [record.excerpt, record.redactedExcerpt] {
                let cleaned = removingCalendarDates(from: excerpt)
                values.append(contentsOf: numericCandidates(in: cleaned))
                values.append(contentsOf: currencyPrefixedCandidates(in: cleaned))
            }
        }
        // 同一 claim 引用多个已校验金额时，允许正文展示可复算占比，
        // 例如“餐饮 25,800 / 总支出 82,400 = 31.3%”。
        for numerator in sourceValues {
            for denominator in sourceValues where denominator != 0 && numerator != denominator {
                values.append(abs(numerator / denominator))
                values.append(abs(numerator / denominator * 100))
            }
        }
        return values
    }

    /// 这些数字来自本地工具的指标定义，不是模型自由生成的个性化目标。
    /// 仅当 claim 确实引用对应 metricKey 时才允许出现在正文中。
    private static func semanticConstants(for metricKey: String) -> [Double] {
        switch metricKey {
        case "health.steps.goal_met_days":
            return [10_000]
        case "health.sleep.goal_met_days":
            return [8]
        case "health.sleep.low_days":
            return [6]
        case "health.stand.goal_met_days":
            return [12]
        case "health.activity.goal_met_days":
            return [30]
        default:
            return []
        }
    }

    private static func removingCalendarDates(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\d{4}\s*年(?:\s*\d{1,2}\s*月)?(?:\s*\d{1,2}\s*日)?"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"\d{1,2}\s*月\s*\d{1,2}\s*日"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func numericCandidates(in text: String) -> [Double] {
        let pattern = #"([0-9][0-9,]*(?:\.[0-9]+)?)(?:\s*[-~～至到]\s*([0-9][0-9,]*(?:\.[0-9]+)?))?\s*(万元|万|元|块|%|％|次|个月|月|天|周|小时|分钟|步)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).flatMap { match -> [Double] in
            guard let unitRange = Range(match.range(at: 3), in: text) else { return [] }
            let multiplier = text[unitRange].hasPrefix("万") ? 10_000.0 : 1.0
            return [1, 2].compactMap { index in
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: text) else { return nil }
                let raw = text[range].replacingOccurrences(of: ",", with: "")
                return Double(raw).map { $0 * multiplier }
            }
        }
    }

    private static func currencyPrefixedCandidates(in text: String) -> [Double] {
        let pattern = #"[¥￥]\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[range].replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(0.51, abs(rhs) * 0.015)
        return abs(lhs - rhs) <= tolerance
    }
}
