//
//  HoloMemoryAnchorRegistry.swift
//  Holo
//
//  类型化 anchor 的候选、确认与解析
//

import Foundation

enum HoloMemoryAnchorProposalSource: String, Codable, Sendable {
    case model
    case deterministicRule
    case user
}

enum HoloMemoryAnchorConfirmationSource: String, Codable, Sendable {
    case localEntityMatch
    case deterministicNormalization
    case user
}

struct HoloMemoryAnchorAliasCandidate: Codable, Equatable, Hashable, Sendable {
    var alias: String
    var suggestedAnchor: HoloMemoryAnchorRef
    var proposedBy: HoloMemoryAnchorProposalSource
}

struct HoloMemoryAnchorRegistry: Codable, Equatable, Sendable {
    private(set) var pendingCandidates: Set<HoloMemoryAnchorAliasCandidate> = []
    private var confirmedAliases: [String: HoloMemoryAnchorRef] = [:]

    mutating func propose(_ candidate: HoloMemoryAnchorAliasCandidate) {
        pendingCandidates.insert(candidate)
    }

    mutating func confirm(
        _ candidate: HoloMemoryAnchorAliasCandidate,
        confirmedBy: HoloMemoryAnchorConfirmationSource
    ) {
        // confirmedBy 由调用层审计；只有显式进入该方法才可写 canonical 映射。
        _ = confirmedBy
        pendingCandidates.remove(candidate)
        confirmedAliases[aliasKey(candidate.alias, type: candidate.suggestedAnchor.type)] =
            candidate.suggestedAnchor
    }

    func resolve(_ alias: String, type: HoloMemoryAnchorType) -> HoloMemoryAnchorRef? {
        confirmedAliases[aliasKey(alias, type: type)]
    }

    private func aliasKey(_ alias: String, type: HoloMemoryAnchorType) -> String {
        let normalized = alias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return "\(type.rawValue)|\(normalized)"
    }
}
