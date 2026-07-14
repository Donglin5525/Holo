//
//  ThoughtMemorySignalBuilder.swift
//  Holo
//
//  区分用户原话、明确立场与 AI 摘要；普通一次随想不升级为稳定人格标签。
//

import Foundation

nonisolated struct ThoughtMemoryInput: Equatable, Sendable {
    var id: String
    var originalText: String
    var explicitStance: String?
    var aiSummary: String?
    var topic: String
    var revisionDigest: String
    var createdAt: Date
}

nonisolated enum ThoughtMemorySignalBuilder {
    static func build(from inputs: [ThoughtMemoryInput]) -> [HoloDomainMemorySignal] {
        let explicit = inputs.filter {
            !$0.id.isEmpty && !$0.revisionDigest.isEmpty &&
            $0.explicitStance?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return explicit.compactMap { input in
            guard let anchor = try? HoloMemoryAnchorRef(
                type: .thoughtTopic,
                value: input.topic,
                displayLabel: input.topic
            ) else { return nil }
            let evidence = HoloMemoryEvidenceRef(
                id: "thought-\(input.id)-\(input.revisionDigest)",
                kind: .explicitUserStatement,
                sourceDomain: .thought,
                lineageKey: "thought:\(input.id)",
                sourceID: input.id,
                revisionDigest: input.revisionDigest,
                observedAt: input.createdAt
            )
            return try? HoloDomainSignalBuilder.make(
                id: "thought-explicit-stance-\(input.id)",
                domain: .thought,
                kind: .explicitUserText,
                evidence: evidence,
                anchors: [anchor],
                prohibitedInferences: [
                    "一次随想不得升级为人格、价值观或永久偏好标签",
                    "AI 摘要不得替代用户原话或作为独立证据"
                ],
                userText: input.originalText,
                explicitUserStance: input.explicitStance,
                aiSummary: input.aiSummary
            )
        }.sorted { $0.id < $1.id }
    }
}
