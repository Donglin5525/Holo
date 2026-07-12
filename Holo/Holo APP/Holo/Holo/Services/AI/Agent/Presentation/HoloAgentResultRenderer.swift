//
//  HoloAgentResultRenderer.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.4 Agent Result Renderer
//  把校验后的 claim + evidence 渲染成手机可读短文。
//  证据引用只使用 redactedExcerpt（脱敏），不暴露完整敏感原文；不输出 Markdown 表格/代码块。
//

import Foundation

nonisolated struct HoloRenderedAgentSection: Codable, Equatable, Sendable {
    var title: String
    var body: String
    /// claim 置信度，可选；旧 JSON 缺失该字段解码为 nil（向后兼容）
    var confidence: Double?
}

nonisolated struct HoloRenderedFinanceDrilldown: Codable, Equatable, Sendable {
    var sourceEvidenceID: String
    var label: String
    var keyword: String?
    var start: Date
    var end: Date
    var baselineStart: Date?
    var baselineEnd: Date?
}

nonisolated struct HoloRenderedEvidenceReference: Codable, Equatable, Sendable {
    var id: String
    var summary: String
    var financeDrilldown: HoloRenderedFinanceDrilldown?
    var sourceModule: HoloEvidenceSourceModule? = nil
}

nonisolated struct HoloRenderedAgentResult: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
    var question: String? = nil
    var headline: String? = nil
    var directAnswer: String? = nil
    var coverageText: String? = nil
    var limitations: [String]? = nil
}

nonisolated struct HoloAgentResultRenderer {

    /// 渲染校验后的 claims 与证据为手机可读结构。
    func render(
        claims: [HoloAgentClaim],
        evidence: [HoloEvidenceRecord],
        title: String = "本期观察",
        question: String? = nil,
        coverage: HoloDataCoverage? = nil
    ) -> HoloRenderedAgentResult {
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assertions = claims.flatMap(\.metricAssertions)
        let primaryAssertion = Self.primaryAssertion(for: question, assertions: assertions)
        let rangeLabel = Self.rangeLabel(question: question, evidence: evidence)
        let headline = Self.headline(
            question: question,
            rangeLabel: rangeLabel,
            assertions: assertions,
            fallbackTitle: title
        )
        let directAnswer = Self.directAnswer(
            question: question,
            rangeLabel: rangeLabel,
            primaryAssertion: primaryAssertion,
            claims: claims
        )
        let sections = Self.sections(
            claims: claims,
            primaryMetricKey: primaryAssertion?.metricKey,
            directAnswer: directAnswer
        )

        // 证据引用：去重，只用 redactedExcerpt。
        // 优先用 metricAssertions 里已校验有效的 evidenceIDs（Verifier 保证其存在），
        // 顶层 claim.evidenceIDs 仅作补充。canonical evidence ID 是 UUID 拼接的长串，
        // LLM 在顶层常写错，找不到 record 的直接跳过，不再显示「证据缺失」。
        var seen = Set<String>()
        var references: [HoloRenderedEvidenceReference] = []
        for claim in claims {
            let candidateIDs = claim.metricAssertions.flatMap(\.evidenceIDs) + claim.evidenceIDs
            for evidenceID in candidateIDs where !seen.contains(evidenceID) {
                seen.insert(evidenceID)
                guard let record = evidenceByID[evidenceID] else { continue }
                references.append(HoloRenderedEvidenceReference(
                    id: evidenceID,
                    summary: Self.readableEvidenceSummary(record),
                    financeDrilldown: Self.financeDrilldown(for: record),
                    sourceModule: record.sourceModule
                ))
            }
        }

        let summary = claims.isEmpty
            ? "本期暂无显著观察"
            : directAnswer ?? sections.map(\.body).joined(separator: "；")

        return HoloRenderedAgentResult(
            title: title,
            summary: summary,
            sections: sections,
            evidenceReferences: references,
            question: question,
            headline: headline,
            directAnswer: directAnswer,
            coverageText: Self.coverageText(coverage, rangeLabel: rangeLabel),
            limitations: []
        )
    }

    private static func primaryAssertion(
        for question: String?,
        assertions: [HoloMetricAssertion]
    ) -> HoloMetricAssertion? {
        guard !assertions.isEmpty else { return nil }
        let normalized = question?.lowercased() ?? ""

        let preferredKey: String?
        if normalized.contains("步数") || normalized.contains("走路") {
            preferredKey = normalized.contains("平均") || normalized.contains("日均")
                ? "health.steps.average"
                : nil
        } else if normalized.contains("睡眠") {
            preferredKey = "health.sleep.average_hours"
        } else if normalized.contains("站立") || normalized.contains("久坐") {
            preferredKey = "health.stand.average_hours"
        } else if normalized.contains("活动") {
            preferredKey = "health.activity.average_minutes"
        } else if normalized.contains("花") || normalized.contains("支出") || normalized.contains("消费") {
            preferredKey = normalized.contains("次数") || normalized.contains("几次")
                ? "finance.keyword.count"
                : "finance.total.amount"
        } else {
            preferredKey = nil
        }

        if let preferredKey,
           let exact = assertions.first(where: { $0.metricKey == preferredKey }) {
            return exact
        }
        if normalized.contains("平均") || normalized.contains("日均") {
            return assertions.first {
                let key = $0.metricKey.lowercased()
                return key.contains("average") || key.contains("mean") || key.contains("per_day")
            } ?? assertions.first
        }
        if normalized.contains("总") || normalized.contains("合计") {
            return assertions.first {
                let key = $0.metricKey.lowercased()
                return key.contains("total") || key.contains("sum")
            } ?? assertions.first
        }
        return assertions.first
    }

    private static func rangeLabel(question: String?, evidence: [HoloEvidenceRecord]) -> String {
        let text = question ?? ""
        let candidates = [
            "最近一个月", "近一个月", "过去一个月", "最近 30 天", "最近30天",
            "这个月", "本月", "上个月", "上月", "最近两周", "近两周",
            "最近一周", "近一周", "本周", "今天", "昨日", "昨天"
        ]
        if let matched = candidates.first(where: { text.contains($0) }) {
            return matched == "这个月" ? "本月" : matched
        }
        return evidence.compactMap { $0.timeRange?.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "本期"
    }

    private static func headline(
        question: String?,
        rangeLabel: String,
        assertions: [HoloMetricAssertion],
        fallbackTitle: String
    ) -> String {
        let text = question ?? ""
        var topics: [String] = []
        if text.contains("步数") || text.contains("走路") { topics.append("步数") }
        if text.contains("睡眠") { topics.append("睡眠") }
        if text.contains("站立") || text.contains("久坐") { topics.append("站立") }
        if text.contains("活动") { topics.append("活动") }
        if text.contains("运动") || text.contains("锻炼") { topics.append("运动") }
        if text.contains("支出") || text.contains("消费") || text.contains("花钱") || text.contains("花哪") { topics.append("支出") }
        if text.contains("习惯") { topics.append("习惯") }
        if text.contains("任务") || text.contains("待办") { topics.append("任务") }
        if text.contains("目标") { topics.append("目标") }
        if text.contains("想法") || text.contains("观点") { topics.append("想法") }

        if topics.isEmpty {
            topics = assertions.map { HoloMetricSemanticCatalog.topic(for: $0.metricKey) }
                .filter { $0 != "数据" }
        }
        topics = topics.reduce(into: []) { result, topic in
            if !result.contains(topic) { result.append(topic) }
        }

        if topics.count > 1 {
            return "\(rangeLabel)的\(topics.joined(separator: "与"))变化"
        }
        switch topics.first {
        case "步数": return "\(rangeLabel)的步数"
        case "睡眠": return "\(rangeLabel)的睡眠情况"
        case "站立": return "\(rangeLabel)的站立情况"
        case "活动": return "\(rangeLabel)的活动情况"
        case "运动": return "\(rangeLabel)的运动情况"
        case "支出": return text.contains("哪") || text.contains("结构") ? "\(rangeLabel)的支出去向" : "\(rangeLabel)的支出"
        case "习惯": return "\(rangeLabel)的习惯进展"
        case "任务": return "\(rangeLabel)的任务进展"
        case "目标": return "\(rangeLabel)的目标进展"
        case "想法": return "\(rangeLabel)的想法脉络"
        case let topic?: return "\(rangeLabel)的\(topic)"
        case nil:
            let cleaned = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty || cleaned == "深度分析" || cleaned == "本期观察"
                ? "\(rangeLabel)的数据结果"
                : cleaned
        }
    }

    private static func directAnswer(
        question: String?,
        rangeLabel: String,
        primaryAssertion: HoloMetricAssertion?,
        claims: [HoloAgentClaim]
    ) -> String? {
        if let assertion = primaryAssertion,
           let sentence = HoloMetricSemanticCatalog.sentence(
               metricKey: assertion.metricKey,
               value: assertion.value,
               unit: assertion.unit,
               comparison: assertion.comparison
           ) {
            if assertion.metricKey == "health.steps.average", let value = assertion.value {
                let number = HoloMetricSemanticCatalog.formattedNumber(
                    value,
                    metricKey: assertion.metricKey,
                    unit: assertion.unit
                )
                return "\(rangeLabel)，日均 \(number) 步"
            }
            return "\(rangeLabel)，\(sentence)"
        }
        return claims.map(\.displayText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !HoloMetricSemanticCatalog.containsInternalToken($0) }
    }

    private static func sections(
        claims: [HoloAgentClaim],
        primaryMetricKey: String?,
        directAnswer: String?
    ) -> [HoloRenderedAgentSection] {
        var output: [HoloRenderedAgentSection] = []
        var seenBodies = Set<String>()

        for claim in claims {
            let rawBody = claim.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            let mustRebuild = HoloMetricSemanticCatalog.containsInternalToken(rawBody)

            if mustRebuild {
                for assertion in claim.metricAssertions where assertion.metricKey != primaryMetricKey {
                    guard let body = HoloMetricSemanticCatalog.sentence(
                        metricKey: assertion.metricKey,
                        value: assertion.value,
                        unit: assertion.unit,
                        comparison: assertion.comparison
                    ) else { continue }
                    appendSection(
                        title: HoloMetricSemanticCatalog.title(for: assertion.metricKey),
                        body: body,
                        confidence: claim.confidence,
                        directAnswer: directAnswer,
                        seenBodies: &seenBodies,
                        output: &output
                    )
                }
                continue
            }

            guard !rawBody.isEmpty else { continue }
            let metricTitle = claim.metricAssertions.first.map {
                HoloMetricSemanticCatalog.title(for: $0.metricKey)
            }
            let resolvedTitle = metricTitle == nil || metricTitle == "计算结果"
                ? shortTitle(from: rawBody)
                : metricTitle!
            appendSection(
                title: resolvedTitle,
                body: rawBody,
                confidence: claim.confidence,
                directAnswer: directAnswer,
                seenBodies: &seenBodies,
                output: &output
            )
        }
        return output
    }

    private static func appendSection(
        title: String,
        body: String,
        confidence: Double,
        directAnswer: String?,
        seenBodies: inout Set<String>,
        output: inout [HoloRenderedAgentSection]
    ) {
        let normalized = normalize(body)
        guard !normalized.isEmpty,
              !seenBodies.contains(normalized),
              normalize(directAnswer ?? "") != normalized else { return }
        seenBodies.insert(normalized)
        var uniqueTitle = title
        if output.contains(where: { $0.title == uniqueTitle }) {
            uniqueTitle = shortTitle(from: body)
        }
        if uniqueTitle == body || uniqueTitle.isEmpty { uniqueTitle = "数据解读" }
        output.append(HoloRenderedAgentSection(title: uniqueTitle, body: body, confidence: confidence))
    }

    private static func shortTitle(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["观察", "本期"] where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
        }
        let separators = Set("，,；;。.!！?？：:\n")
        let first = cleaned.split { separators.contains($0) }.first.map(String.init) ?? cleaned
        let title = String(first.prefix(14)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "数据解读" : title
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !"，,；;。.!！?？：:".contains($0) }
    }

    private static func coverageText(_ coverage: HoloDataCoverage?, rangeLabel: String) -> String? {
        guard let coverage else { return nil }
        return "\(rangeLabel)共 \(coverage.totalDays) 天，其中 \(coverage.coveredDays)/\(coverage.totalDays) 天有有效记录"
    }

    private static func readableEvidenceSummary(_ record: HoloEvidenceRecord) -> String {
        let summary = record.redactedExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HoloMetricSemanticCatalog.containsInternalToken(summary) else { return summary }
        return HoloMetricSemanticCatalog.sentence(
            metricKey: record.metricKey,
            value: record.metricValue,
            unit: record.unit,
            comparison: record.comparison
        ) ?? "该数据已完成核对"
    }

    private static func financeDrilldown(for record: HoloEvidenceRecord) -> HoloRenderedFinanceDrilldown? {
        guard record.sourceModule == .finance,
              let range = record.timeRange,
              let start = range.start,
              let end = range.end else {
            return nil
        }
        return HoloRenderedFinanceDrilldown(
            sourceEvidenceID: record.id,
            label: range.label,
            keyword: keyword(from: record),
            start: start,
            end: end,
            baselineStart: record.baselineTimeRange?.start,
            baselineEnd: record.baselineTimeRange?.end
        )
    }

    private static func keyword(from record: HoloEvidenceRecord) -> String? {
        guard record.metricKey.hasPrefix("finance.keyword.") else { return nil }
        return quotedKeyword(in: record.redactedExcerpt) ?? quotedKeyword(in: record.excerpt)
    }

    private static func quotedKeyword(in text: String) -> String? {
        guard let start = text.firstIndex(of: "「") else { return nil }
        let afterStart = text.index(after: start)
        guard let end = text[afterStart...].firstIndex(of: "」") else { return nil }
        let keyword = String(text[afterStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }
}
