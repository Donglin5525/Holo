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
}

nonisolated struct HoloRenderedAgentResult: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
}

nonisolated struct HoloAgentResultRenderer {

    /// 渲染校验后的 claims 与证据为手机可读结构。
    func render(claims: [HoloAgentClaim], evidence: [HoloEvidenceRecord],
                title: String = "本期观察") -> HoloRenderedAgentResult {
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // section.title 用「观察 N」作为短 kicker，body 用 claim 正文；二者不再同值
        let sections = claims.enumerated().map { index, claim in
            HoloRenderedAgentSection(
                title: "观察 \(index + 1)",
                body: claim.displayText,
                confidence: claim.confidence
            )
        }

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
                    summary: record.redactedExcerpt,
                    financeDrilldown: Self.financeDrilldown(for: record)
                ))
            }
        }

        let summary = claims.isEmpty
            ? "本期暂无显著观察"
            : claims.map(\.displayText).joined(separator: "；")

        return HoloRenderedAgentResult(
            title: title,
            summary: summary,
            sections: sections,
            evidenceReferences: references
        )
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
