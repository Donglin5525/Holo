//
//  HoloAgentResultRenderer.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 4.4 Agent Result Renderer
//  把校验后的 claim + evidence 渲染成手机可读短文。
//  证据引用只使用 redactedExcerpt（脱敏），不暴露完整敏感原文；不输出 Markdown 表格/代码块。
//

import Foundation

struct HoloRenderedAgentSection: Codable, Equatable, Sendable {
    var title: String
    var body: String
    /// claim 置信度，可选；旧 JSON 缺失该字段解码为 nil（向后兼容）
    var confidence: Double?
}

struct HoloRenderedFinanceDrilldown: Codable, Equatable, Sendable {
    var sourceEvidenceID: String
    var label: String
    var keyword: String?
    var start: Date
    var end: Date
    var baselineStart: Date?
    var baselineEnd: Date?
}

struct HoloRenderedEvidenceReference: Codable, Equatable, Sendable {
    var id: String
    var summary: String
    var financeDrilldown: HoloRenderedFinanceDrilldown?
}

struct HoloRenderedAgentResult: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
}

struct HoloAgentResultRenderer {

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

        // 证据引用：去重，只用 redactedExcerpt
        var seen = Set<String>()
        var references: [HoloRenderedEvidenceReference] = []
        for claim in claims {
            for evidenceID in claim.evidenceIDs where !seen.contains(evidenceID) {
                seen.insert(evidenceID)
                let record = evidenceByID[evidenceID]
                references.append(HoloRenderedEvidenceReference(
                    id: evidenceID,
                    summary: record?.redactedExcerpt ?? "（证据缺失）",
                    financeDrilldown: record.flatMap(Self.financeDrilldown)
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
