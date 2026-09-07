//
//  HoloSemanticTombstoneMatcher.swift
//  Holo
//
//  以 canonical anchors 与 claim family 阻止被忘记内容换一种说法重新出现。
//

import Foundation

nonisolated enum HoloMemoryClaimFamily: String, Sendable {
    case fact
    case pattern
    case relationship
}

nonisolated enum HoloSemanticTombstoneMatcher {
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
        if matches(
            tombstone: tombstone,
            scope: record.scope,
            claimKind: record.claimKind,
            anchors: record.anchorRefs
        ) {
            return true
        }
        // 情境命名空间的非正文键匹配：ctx- 前缀键不当普通业务 anchor，
        // 命中即认为被压制（换 contextID 重生同一命题时拦截）。
        if let payload = record.personalContext?.v1 {
            return contextSuppressionMatches(tombstone: tombstone, payload: payload)
        }
        return false
    }

    /// 情境记录的 suppression 匹配：候选的 span 键与墓碑里的 ctx- 键相交即压制。
    /// 命题参与键组成，同来源不同命题不会误伤。
    static func contextSuppressionMatches(
        tombstone: HoloMemoryTombstone,
        payload: HoloPersonalContextPayloadV1
    ) -> Bool {
        let tombstoneContextKeys = HoloContextSuppressionKeys.contextKeys(in: tombstone.anchorKeys)
        guard !tombstoneContextKeys.isEmpty else { return false }
        let candidateKeys = Set(HoloContextSuppressionKeys.spanKeys(for: payload))
        return !candidateKeys.isEmpty && !candidateKeys.isDisjoint(with: tombstoneContextKeys)
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
