//
//  HoloSemanticTombstoneMatcher.swift
//  Holo
//
//  以 canonical anchors 与 claim family 阻止被忘记内容换一种说法重新出现。
//

import Foundation

enum HoloMemoryClaimFamily: String, Sendable {
    case fact
    case pattern
    case relationship
}

enum HoloSemanticTombstoneMatcher {
    static func matches(
        tombstone: HoloMemoryTombstone,
        scope: HoloMemoryScope,
        claimKind: HoloMemoryClaimKind,
        anchors: [HoloMemoryAnchorRef]
    ) -> Bool {
        guard tombstone.scope == scope,
              family(for: tombstone.claimKind) == family(for: claimKind) else {
            return false
        }
        let candidateKeys = Set(HoloMemoryIdentity.canonicalAnchors(anchors).map(\.stableKey))
        return !candidateKeys.isEmpty && candidateKeys == Set(tombstone.anchorKeys)
    }

    static func matches(
        tombstone: HoloMemoryTombstone,
        record: HoloMemoryRecord
    ) -> Bool {
        matches(
            tombstone: tombstone,
            scope: record.scope,
            claimKind: record.claimKind,
            anchors: record.anchorRefs
        )
    }

    private static func family(for kind: HoloMemoryClaimKind) -> HoloMemoryClaimFamily {
        switch kind {
        case .observedFact, .explicitPreference, .lifeEvent:
            return .fact
        case .recurringPattern, .phaseShift:
            return .pattern
        case .association, .tension, .hypothesis:
            return .relationship
        }
    }
}
