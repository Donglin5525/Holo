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
}

struct HoloRenderedEvidenceReference: Codable, Equatable, Sendable {
    var id: String
    var summary: String
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
        let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })

        let sections = claims.map { claim in
            HoloRenderedAgentSection(title: claim.displayText, body: claim.displayText)
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
                    summary: record?.redactedExcerpt ?? "（证据缺失）"
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
}
