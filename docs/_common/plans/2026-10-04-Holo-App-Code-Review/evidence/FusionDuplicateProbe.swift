import Foundation

// 仅创建合成记录并调用生产构建器，不读写 App 数据或修改功能开关。
@main struct FusionDuplicateProbe {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "恢复状态")
        var finance = try makeRecord(domain: .finance, anchor: anchor, lineage: "finance-event-1", start: now.addingTimeInterval(-604800), end: now)
        var health = try makeRecord(domain: .health, anchor: anchor, lineage: "health-sleep-1", start: now.addingTimeInterval(-432000), end: now.addingTimeInterval(172800))
        finance.anchorRefs.append(anchor)
        health.anchorRefs.append(anchor)
        try finance.validate()
        try health.validate()
        print("duplicate anchors passed validate; entering actual builder without changing flags")
        let candidates = HoloCrossDomainCandidateBuilder.build(from: [finance, health])
        print("returned", candidates.count)
    }
    private static func makeRecord(
        domain: HoloMemoryDomain,
        anchor: HoloMemoryAnchorRef,
        lineage: String,
        start: Date,
        end: Date,
        sourceID: String? = nil,
        claimKind: HoloMemoryClaimKind = .recurringPattern
    ) throws -> HoloMemoryRecord {
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(domain.rawValue)-\(lineage)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: lineage,
            sourceID: sourceID,
            revisionDigest: "rev-1",
            observedAt: end,
            validFrom: start,
            validTo: end,
            aggregateDefinition: "test",
            sampleCount: 7,
            summary: "测试证据"
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .currentState,
            displaySummary: "\(domain.rawValue) 近期状态",
            aiUseSummary: "\(domain.rawValue) 近期状态",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: start,
            validTo: end,
            lastSupportedAt: end,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: end,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: start,
            updatedAt: end
        )
    }

}
