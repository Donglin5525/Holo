//
//  HoloMemoryIdentity.swift
//  Holo
//
//  统一记忆的稳定语义身份
//

import Foundation

nonisolated enum HoloMemoryIdentity {
    /// 锚点规范化（R04，2026-10-04 体检）：输出按 stableKey 去重且顺序确定。
    /// 折叠规则：完全重复折叠为一条；同 stableKey 仅 displayLabel 不同的冲突重复，
    /// 按 (stableKey, displayLabel) 字典序保留最小一条——确定性规则，禁止随数组顺序
    /// 随机保留。融合构建器以此为唯一键构造字典，历史脏数据（解码绕过 init 规范化）
    /// 也必须走此出口获得键唯一性。
    static func canonicalAnchors(_ anchors: [HoloMemoryAnchorRef]) -> [HoloMemoryAnchorRef] {
        var seen = Set<String>()
        return anchors
            .sorted { ($0.stableKey, $0.displayLabel ?? "") < ($1.stableKey, $1.displayLabel ?? "") }
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
