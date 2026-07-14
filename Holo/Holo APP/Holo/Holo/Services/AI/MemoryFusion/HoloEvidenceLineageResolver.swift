//
//  HoloEvidenceLineageResolver.swift
//  Holo
//
//  跨域融合只计算独立底层证据，避免同一业务事件被多个摘要重复计票。
//

import Foundation

enum HoloEvidenceLineageResolver {
    static func independentEvidence(
        from memories: [HoloMemoryRecord]
    ) -> [HoloMemoryEvidenceRef] {
        var seen = Set<String>()
        return memories
            .flatMap(\.evidenceRefs)
            .filter(isFactEvidence)
            .sorted {
                if $0.observedAt == $1.observedAt { return $0.id < $1.id }
                return $0.observedAt < $1.observedAt
            }
            .filter { seen.insert($0.lineageKey).inserted }
    }

    static func isFactEvidence(_ evidence: HoloMemoryEvidenceRef) -> Bool {
        let lineage = evidence.lineageKey.lowercased()
        let sourceID = evidence.sourceID?.lowercased() ?? ""
        let definition = evidence.aggregateDefinition?.lowercased() ?? ""
        let forbiddenPrefixes = ["memory-insight:", "memory_insight:", "insight:"]
        return !forbiddenPrefixes.contains(where: {
            lineage.hasPrefix($0) || sourceID.hasPrefix($0)
        }) && !definition.contains("memoryinsight") && !definition.contains("memory_insight")
    }
}
