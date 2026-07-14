import Foundation

@main
struct HoloMemoryLifecycleStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    private static func evidence(_ id: String, lineage: String? = nil) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: id,
            kind: .entityRef,
            sourceDomain: .habit,
            lineageKey: lineage ?? id,
            sourceID: id,
            revisionDigest: "revision-\(id)",
            observedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private static func makeRecord() throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .habit, value: "running")
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: "跑步",
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .durable,
            displaySummary: "保持跑步节奏",
            aiUseSummary: "用户保持跑步节奏",
            prohibitedInferences: [],
            evidenceRefs: [evidence("support-1"), evidence("support-2")],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.85,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_721_000_000)
        let original = try makeRecord()

        let firstCounter = HoloMemoryLifecycle.apply(
            .counterEvidence(evidence("counter-1")),
            to: original,
            now: now
        )
        expect(firstCounter.state == .active,
               "第一次反例只应降低支持度，不立即进入 disputed")
        expect(firstCounter.confidenceScore < original.confidenceScore,
               "反例必须降低成立置信度")

        let secondCounter = HoloMemoryLifecycle.apply(
            .counterEvidence(evidence("counter-2")),
            to: firstCounter,
            now: now.addingTimeInterval(1)
        )
        expect(secondCounter.state == .disputed,
               "连续独立反例必须进入 disputed")

        let confirmed = HoloMemoryLifecycle.apply(.userConfirmed, to: original, now: now)
        let confirmedWithCounter = HoloMemoryLifecycle.apply(
            .counterEvidence(evidence("counter-confirmed")),
            to: confirmed,
            now: now.addingTimeInterval(1)
        )
        expect(confirmedWithCounter.userDecision == .confirmed,
               "自动事件不能覆盖用户确认")
        expect(confirmedWithCounter.state == .active,
               "用户确认记忆不能被自动反例直接降为 disputed")

        let superseded = HoloMemoryLifecycle.apply(
            .superseded(byVersionID: "replacement@v2"),
            to: original,
            now: now
        )
        expect(superseded.state == .superseded,
               "明确替代必须进入 superseded")
        expect(superseded.supersedesMemoryID == "replacement@v2",
               "替代 lineage 必须保留")

        let correctionEvidence = HoloMemoryEvidenceRef(
            id: "user-correction",
            kind: .explicitUserStatement,
            sourceDomain: .habit,
            lineageKey: "conversation-message-1",
            sourceID: "message-1",
            revisionDigest: "message-v1",
            observedAt: now
        )
        let correction = HoloMemoryLifecycle.correct(
            original,
            displaySummary: "近期跑步节奏并不稳定",
            aiUseSummary: "用户明确纠正：近期跑步节奏不稳定",
            evidence: correctionEvidence,
            now: now
        )
        expect(correction.previous.state == .superseded,
               "用户纠正后旧版本必须保留为 superseded")
        expect(correction.corrected.recordVersion == original.recordVersion + 1,
               "用户纠正必须生成新版本")
        expect(correction.corrected.predecessorVersionID == original.versionID,
               "用户纠正必须保留版本 lineage")
        expect(correction.corrected.userDecision == .corrected,
               "纠正版本必须具有最高优先级用户决定")

        var oldScoringVersion = original
        oldScoringVersion.scoringVersion = HoloMemoryScorer.currentVersion - 1
        let recalculated = HoloMemoryLifecycle.recalculateScoresIfNeeded(
            oldScoringVersion,
            now: now
        )
        expect(recalculated.scoringVersion == HoloMemoryScorer.currentVersion,
               "scoringVersion 变化必须触发重算")
        expect(recalculated.scoreComputedAt == now,
               "重算必须更新时间戳")

        print("HoloMemoryLifecycleStandaloneTests passed: \(assertionCount) assertions")
    }
}
