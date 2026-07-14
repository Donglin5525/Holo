//
//  HoloMemoryIdentity.swift
//  Holo
//
//  统一记忆的稳定语义身份
//

import Foundation

enum HoloMemoryIdentity {
    static func canonicalAnchors(_ anchors: [HoloMemoryAnchorRef]) -> [HoloMemoryAnchorRef] {
        var seen = Set<String>()
        return anchors
            .sorted { $0.stableKey < $1.stableKey }
            .filter { seen.insert($0.stableKey).inserted }
    }

    static func makeStableID(for record: HoloMemoryRecord) throws -> String {
        try makeStableID(
            scope: record.scope,
            primaryDomain: record.primaryDomain,
            sourceDomains: record.sourceDomains,
            claimKind: record.claimKind,
            anchors: record.anchorRefs
        )
    }

    static func makeStableID(
        scope: HoloMemoryScope,
        primaryDomain: HoloMemoryDomain?,
        sourceDomains: [HoloMemoryDomain],
        claimKind: HoloMemoryClaimKind,
        anchors: [HoloMemoryAnchorRef]
    ) throws -> String {
        let canonical = canonicalAnchors(anchors)
        guard !canonical.isEmpty else { throw HoloMemorySchemaError.missingCanonicalAnchor }

        let domains = Array(Set(sourceDomains)).sorted()
        switch scope {
        case .domain:
            guard let primaryDomain, domains == [primaryDomain] else {
                throw HoloMemorySchemaError.invalidDomainScope
            }
        case .crossDomain:
            guard primaryDomain == nil, domains.count >= 2 else {
                throw HoloMemorySchemaError.invalidCrossDomainScope
            }
        }

        let identity = [
            scope.rawValue,
            primaryDomain?.rawValue ?? "none",
            domains.map(\.rawValue).joined(separator: ","),
            claimKind.rawValue,
            canonical.map(\.stableKey).joined(separator: ",")
        ].joined(separator: "|")
        return "holo-memory-v3-\(fnv1a64(identity))"
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
