//
//  HoloCrossDomainCandidateBuilder.swift
//  Holo
//
//  用共同时间、共同锚点、跨领域和独立证据四道门筛选融合候选。
//

import Foundation

struct HoloCrossDomainTimeWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
}

struct HoloCrossDomainFusionCandidate: Codable, Equatable, Sendable {
    var identityKey: String
    var sharedAnchor: HoloMemoryAnchorRef
    var sourceMemoryIDs: [String]
    var sourceDomains: [HoloMemoryDomain]
    var memories: [HoloMemoryRecord]
    var evidenceRefs: [HoloMemoryEvidenceRef]
    var commonWindow: HoloCrossDomainTimeWindow
}

enum HoloCrossDomainCandidateBuilder {
    static func build(from records: [HoloMemoryRecord]) -> [HoloCrossDomainFusionCandidate] {
        let eligible = records
            .filter(isEligibleDomainMemory)
            .sorted { $0.id < $1.id }
        var candidates: [HoloCrossDomainFusionCandidate] = []
        var seen = Set<String>()

        for leftIndex in eligible.indices {
            for rightIndex in eligible.indices where rightIndex > leftIndex {
                let left = eligible[leftIndex]
                let right = eligible[rightIndex]
                guard left.primaryDomain != right.primaryDomain,
                      let window = commonWindow(left, right) else { continue }

                let rightAnchors = Dictionary(
                    uniqueKeysWithValues: right.anchorRefs.map { ($0.stableKey, $0) }
                )
                let sharedAnchors = HoloMemoryIdentity.canonicalAnchors(
                    left.anchorRefs.compactMap { rightAnchors[$0.stableKey] }
                )
                guard !sharedAnchors.isEmpty else { continue }

                let memories = [left, right]
                let evidence = HoloEvidenceLineageResolver.independentEvidence(from: memories)
                guard evidence.count >= 2,
                      Set(evidence.map(\.sourceDomain)).count >= 2 else { continue }

                let domains = Array(Set(memories.compactMap(\.primaryDomain))).sorted()
                guard domains.count >= 2 else { continue }
                let memoryIDs = memories.map(\.id).sorted()

                for anchor in sharedAnchors {
                    let identity = [
                        anchor.stableKey,
                        domains.map(\.rawValue).joined(separator: ","),
                        memoryIDs.joined(separator: ","),
                        String(Int(window.start.timeIntervalSince1970)),
                        String(Int(window.end.timeIntervalSince1970))
                    ].joined(separator: "|")
                    guard seen.insert(identity).inserted else { continue }
                    candidates.append(
                        HoloCrossDomainFusionCandidate(
                            identityKey: identity,
                            sharedAnchor: anchor,
                            sourceMemoryIDs: memoryIDs,
                            sourceDomains: domains,
                            memories: memories,
                            evidenceRefs: evidence,
                            commonWindow: window
                        )
                    )
                }
            }
        }
        return candidates.sorted { $0.identityKey < $1.identityKey }
    }

    private static func isEligibleDomainMemory(_ record: HoloMemoryRecord) -> Bool {
        guard record.scope == .domain,
              record.primaryDomain != nil,
              record.sourceDomains.count == 1,
              record.state == .active else { return false }
        return ![.rejected, .forgotten, .markedIrrelevant].contains(record.userDecision)
    }

    private static func commonWindow(
        _ lhs: HoloMemoryRecord,
        _ rhs: HoloMemoryRecord
    ) -> HoloCrossDomainTimeWindow? {
        guard let lhsStart = lhs.validFrom,
              let lhsEnd = lhs.validTo,
              let rhsStart = rhs.validFrom,
              let rhsEnd = rhs.validTo else { return nil }
        let start = max(lhsStart, rhsStart)
        let end = min(lhsEnd, rhsEnd)
        guard start <= end else { return nil }
        return HoloCrossDomainTimeWindow(start: start, end: end)
    }
}
