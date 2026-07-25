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
        let legacyAnswer = Self.directAnswer(
            question: question,
            rangeLabel: rangeLabel,
            primaryAssertion: primaryAssertion,
            claims: claims,
            evidenceByID: evidenceByID
        )
        let directAnswer = legacyAnswer.text
        let sections = Self.sections(
            claims: claims,
            primaryMetricKey: primaryAssertion?.metricKey,
            directAnswer: directAnswer,
            evidenceByID: evidenceByID
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

        var result = HoloRenderedAgentResult(
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

        // MARK: P4 可观测：语义缺失/旧目录兜底
        // 有证据但全无 semantic → 走了兼容目录；旧目录产出过 catalog 句子 → 兼容适配成功。
        if HoloAgentResultSemanticsFlags.typedSemanticsEnabled,
           !evidence.isEmpty,
           !evidence.contains(where: { $0.semantic != nil }) {
            let legacyContext = evidence.first?.sourceModule.rawValue
            HoloAgentAnswerMetricCounter.shared.increment(.semanticMissing, context: legacyContext)
            if legacyAnswer.usedCatalog {
                HoloAgentAnswerMetricCounter.shared.increment(.semanticLegacyFallback, context: legacyContext)
            }
        }

        // MARK: P2 确定性合成与展示前验证
        // 证据带类型化语义时，直接结论改由本地合成器产出（P3 已删除 financeComparisonAnswer
        // 等领域特判，比较/排名/拆解/趋势统一走合成器），模型文案降为解释层；
        // 无 semantic 的旧证据完全走上方旧逻辑（HoloMetricSemanticCatalog 兼容层）。
        var composed: HoloComposedAnswer?
        if HoloAgentResultSemanticsFlags.typedSemanticsEnabled,
           HoloAgentResultSemanticsFlags.deterministicComposerEnabled,
           let task = HoloAnswerTaskDeriver.derive(question: question, evidence: evidence),
           let answer = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: coverage) {
            composed = answer
            HoloAgentAnswerMetricCounter.shared.increment(.composerUsed, context: task.domain?.rawValue)
            result.headline = answer.headline
            result.directAnswer = answer.directAnswer
            result.summary = answer.directAnswer
            if let composedCoverage = answer.coverageText {
                result.coverageText = composedCoverage
            }
            if !answer.limitations.isEmpty {
                result.limitations = answer.limitations
            }
            // 解释层 section：命中内部 token 的用合成明细顶替，没有可顶替的丢弃。
            var spareItems = answer.items
            result.sections = result.sections.compactMap { section in
                guard HoloAnswerCoverageVerifier.containsInternalToken(section.body)
                        || HoloAnswerCoverageVerifier.containsInternalToken(section.title) else {
                    return section
                }
                HoloAgentAnswerMetricCounter.shared.increment(.internalTokenBlocked, context: "section")
                HoloAgentAnswerMetricCounter.shared.increment(.modelTextDiscarded, context: "section")
                guard !spareItems.isEmpty else { return nil }
                let replacement = spareItems.removeFirst()
                return HoloRenderedAgentSection(title: "数据明细", body: replacement, confidence: section.confidence)
            }
        }

        return Self.deliverVerified(result, evidence: evidence, coverage: coverage, composed: composed)
    }

    /// 展示前验证 + 自动恢复：recoverable 先修复再验一次，仍不过或 failed 一律给边界说明，
    /// 绝不交付含内部 token 的半成品。
    private static func deliverVerified(
        _ result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?,
        composed: HoloComposedAnswer?
    ) -> HoloRenderedAgentResult {
        switch HoloAnswerCoverageVerifier.verify(result: result, evidence: evidence, coverage: coverage) {
        case .pass:
            return result
        case .recoverable(let codes):
            if codes.contains(HoloAnswerCoverageVerifier.codeInternalToken) {
                HoloAgentAnswerMetricCounter.shared.increment(.internalTokenBlocked, context: "verifier")
            }
            let repair = Self.repaired(result, evidence: evidence, coverage: coverage, composed: composed)
            if repair.discardedModelText {
                HoloAgentAnswerMetricCounter.shared.increment(.modelTextDiscarded, context: "verifier_repair")
            }
            let verdict = HoloAnswerCoverageVerifier.verify(result: repair.result, evidence: evidence, coverage: coverage)
            if case .pass = verdict { return repair.result }
            return Self.boundaryResult(from: repair.result, evidence: evidence, composed: composed)
        case .failed(let codes):
            HoloAgentAnswerMetricCounter.shared.increment(.coverageFailed, context: codes.first ?? "UNKNOWN")
            return Self.boundaryResult(from: result, evidence: evidence, composed: composed)
        }
    }

    /// 本地修复：丢弃违规的模型事实文案；违规的 summary/directAnswer 用合成结论或兜底句替换。
    /// 返回修复后的结果与是否丢弃过模型文案（供 P4 指标计数）。
    private static func repaired(
        _ result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?,
        composed: HoloComposedAnswer?
    ) -> (result: HoloRenderedAgentResult, discardedModelText: Bool) {
        // 与 Verifier 一致：已知分组用合成器清洗后的形态，避免合法分组被误判编造。
        let knownLabels = Set(evidence.compactMap {
            HoloDeterministicAnswerComposer.sanitizedGroupLabel($0.semantic?.groupLabel)
        })
        func violates(_ text: String) -> Bool {
            HoloAnswerCoverageVerifier.containsInternalToken(text)
                || HoloAnswerCoverageVerifier.hasDirectionConflict(text, knownLabels: knownLabels)
                || !HoloAnswerCoverageVerifier.unknownGroupMentions(in: text, knownLabels: knownLabels).isEmpty
        }

        var repaired = result
        var discarded = false
        if HoloAnswerCoverageVerifier.containsInternalToken(repaired.title) {
            repaired.title = "本期观察"
            discarded = true
        }
        if let headline = repaired.headline, violates(headline) {
            repaired.headline = composed?.headline
            discarded = true
        }
        if let answer = repaired.directAnswer, violates(answer) {
            repaired.directAnswer = composed?.directAnswer
            discarded = true
        }
        if violates(repaired.summary) {
            repaired.summary = composed?.directAnswer ?? "本期数据结果如下"
            discarded = true
        }
        if let text = repaired.coverageText, violates(text) {
            repaired.coverageText = composed?.coverageText
            discarded = true
        }
        // 覆盖不足未披露时补确定性披露句。
        if let coverage, !HoloAnswerCoverageVerifier.coverageDisclosed(repaired.coverageText) {
            let ratio = coverage.coverageRatio
                ?? (coverage.totalDays > 0 ? Double(coverage.coveredDays) / Double(coverage.totalDays) : 1)
            if ratio < 0.9 {
                repaired.coverageText = composed?.coverageText
                    ?? Self.coverageText(coverage, rangeLabel: "本期")
            }
        }
        let keptSections = repaired.sections.filter { !violates($0.title) && !violates($0.body) }
        if keptSections.count != repaired.sections.count { discarded = true }
        repaired.sections = keptSections
        return (repaired, discarded)
    }

    /// 失败边界：可理解的说明 + 只保留确定性内容，不展示半成品。
    private static func boundaryResult(
        from result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        composed: HoloComposedAnswer?
    ) -> HoloRenderedAgentResult {
        let boundary = "这次分析没能形成可信结论，已为你保留数据明细。"
        var sections: [HoloRenderedAgentSection] = []
        if let composed {
            sections.append(HoloRenderedAgentSection(title: "已核对的数据", body: composed.directAnswer, confidence: nil))
        }
        let coverageText = result.coverageText.flatMap {
            HoloAnswerCoverageVerifier.containsInternalToken($0) ? nil : $0
        }
        return HoloRenderedAgentResult(
            title: HoloAnswerCoverageVerifier.containsInternalToken(result.title) ? "本期观察" : result.title,
            summary: boundary,
            sections: sections,
            evidenceReferences: result.evidenceReferences,
            question: result.question,
            headline: nil,
            directAnswer: boundary,
            coverageText: coverageText,
            limitations: result.limitations
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

    /// 旧逻辑直接结论。`usedCatalog` 表示结论是否由兼容目录（HoloMetricSemanticCatalog）
    /// 的句子产出（P4 指标区分「旧目录可识别适配」与「纯模型文案兜底」）。
    private static func directAnswer(
        question: String?,
        rangeLabel: String,
        primaryAssertion: HoloMetricAssertion?,
        claims: [HoloAgentClaim],
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> (text: String?, usedCatalog: Bool) {
        if let assertion = primaryAssertion,
           let sentence = HoloMetricSemanticCatalog.sentence(
               metricKey: assertion.metricKey,
               value: resolvedValue(for: assertion, evidenceByID: evidenceByID),
               unit: resolvedUnit(for: assertion, evidenceByID: evidenceByID),
               comparison: resolvedComparison(for: assertion, evidenceByID: evidenceByID)
           ) {
            if assertion.metricKey == "health.steps.average", let value = assertion.value {
                let number = HoloMetricSemanticCatalog.formattedNumber(
                    value,
                    metricKey: assertion.metricKey,
                    unit: assertion.unit
                )
                return ("\(rangeLabel)，日均 \(number) 步", true)
            }
            return ("\(rangeLabel)，\(sentence)", true)
        }
        let fallback = claims.map(\.displayText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !HoloMetricSemanticCatalog.containsInternalToken($0) }
        return (fallback, false)
    }

    private static func sections(
        claims: [HoloAgentClaim],
        primaryMetricKey: String?,
        directAnswer: String?,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> [HoloRenderedAgentSection] {
        var output: [HoloRenderedAgentSection] = []
        var seenBodies = Set<String>()

        for claim in claims {
            let rawBody = claim.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            let mustRebuild = HoloMetricSemanticCatalog.containsInternalToken(rawBody)

            if mustRebuild {
                for assertion in claim.metricAssertions where assertion.metricKey != primaryMetricKey {
                    let comparison = resolvedComparison(for: assertion, evidenceByID: evidenceByID)
                    guard let body = HoloMetricSemanticCatalog.sentence(
                        metricKey: assertion.metricKey,
                        value: resolvedValue(for: assertion, evidenceByID: evidenceByID),
                        unit: resolvedUnit(for: assertion, evidenceByID: evidenceByID),
                        comparison: comparison
                    ) else { continue }
                    appendSection(
                        title: HoloMetricSemanticCatalog.title(
                            for: assertion.metricKey,
                            comparison: comparison
                        ),
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
                HoloMetricSemanticCatalog.title(
                    for: $0.metricKey,
                    comparison: resolvedComparison(for: $0, evidenceByID: evidenceByID)
                )
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

    private static func resolvedValue(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> Double? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceValue = matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.metricValue {
            return evidenceValue
        }
        return assertion.value ?? matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.metricValue
    }

    private static func resolvedUnit(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> String? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceUnit = matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.unit {
            return evidenceUnit
        }
        return assertion.unit ?? matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.unit
    }

    private static func resolvedComparison(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> String? {
        if assertion.metricKey.hasPrefix("dynamic."),
           let evidenceComparison = matchingEvidence(
               for: assertion,
               evidenceByID: evidenceByID
           )?.comparison?.trimmingCharacters(in: .whitespacesAndNewlines),
           !evidenceComparison.isEmpty {
            return evidenceComparison
        }
        let comparison = assertion.comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comparison, !comparison.isEmpty { return comparison }
        return matchingEvidence(for: assertion, evidenceByID: evidenceByID)?.comparison
    }

    private static func matchingEvidence(
        for assertion: HoloMetricAssertion,
        evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloEvidenceRecord? {
        assertion.evidenceIDs
            .compactMap { evidenceByID[$0] }
            .first { $0.metricKey == assertion.metricKey }
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
