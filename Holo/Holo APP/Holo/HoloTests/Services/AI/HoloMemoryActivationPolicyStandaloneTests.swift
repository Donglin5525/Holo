import Foundation

@main
struct HoloMemoryActivationPolicyStandaloneTests {
    private static var assertions = 0

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)

        let finance = try makeRecord(domain: .finance, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(finance) ==
                .activateAutomatically(.normalValidatedMemory),
            "普通财务记忆应自动采用"
        )

        let health = try makeRecord(domain: .health, sensitivity: .sensitive, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(health) ==
                .requiresConfirmation(.sensitiveMemory),
            "显式标记敏感的记忆必须等待确认"
        )

        let healthObjective = try makeRecord(domain: .health, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(healthObjective) ==
                .activateAutomatically(.normalValidatedMemory),
            "普通健康统计记忆应自动采用"
        )

        let highImpact = try makeRecord(domain: .finance, sensitivity: .highImpact, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(highImpact) ==
                .requiresConfirmation(.sensitiveMemory),
            "高影响记忆必须等待确认"
        )

        let profile = try makeRecord(domain: .profile, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(profile) ==
                .requiresConfirmation(.profileOrIdentity),
            "身份与 Profile 记忆必须等待确认"
        )
        var identityInConversation = try makeRecord(domain: .conversation, now: now)
        identityInConversation.anchorRefs = [
            try HoloMemoryAnchorRef(type: .profile, value: "identity")
        ]
        expect(
            HoloMemoryActivationPolicy.evaluate(identityInConversation) ==
                .requiresConfirmation(.profileOrIdentity),
            "其他领域中的身份锚点也必须等待确认"
        )

        let hypothesis = try makeRecord(domain: .thought, claimKind: .hypothesis, now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(hypothesis) ==
                .requiresConfirmation(.hypothesis),
            "假设性记忆必须等待确认"
        )

        let permanent = try makeRecord(
            domain: .profile,
            persistenceClass: .permanentFact,
            now: now
        )
        expect(
            HoloMemoryActivationPolicy.evaluate(permanent) ==
                .requiresConfirmation(.profileOrIdentity),
            "永久身份事实必须等待确认"
        )

        let firstCrossDomain = try makeCrossDomainRecord(now: now)
        expect(
            HoloMemoryActivationPolicy.evaluate(
                firstCrossDomain,
                isFirstCrossDomainInference: true
            ) == .requiresConfirmation(.firstCrossDomainInference),
            "首次跨域推断必须等待确认"
        )
        expect(
            HoloMemoryActivationPolicy.evaluate(
                firstCrossDomain,
                isFirstCrossDomainInference: false
            ) == .activateAutomatically(.repeatedCrossDomainInference),
            "重复独立支持的普通跨域推断应自动采用"
        )

        var invalid = finance
        invalid.evidenceRefs = []
        expect(HoloMemoryActivationPolicy.evaluate(invalid) == .discard,
               "缺少证据的输出必须丢弃")

        let staleCurrent = try makeRecord(
            domain: .habit,
            persistenceClass: .currentState,
            lastSupportedAt: now.addingTimeInterval(-40 * 86_400),
            now: now
        )
        expect(HoloMemoryRecallPolicy.needsRefresh(staleCurrent, now: now),
               "有效新鲜度低于 0.35 应触发复查")
        expect(!HoloMemoryRecallPolicy.isEligible(staleCurrent, now: now),
               "有效新鲜度低于 0.20 应退出召回")

        var confirmedStale = staleCurrent
        confirmedStale.userDecision = .confirmed

        let permanentOld = try makeRecord(
            domain: .profile,
            persistenceClass: .permanentFact,
            lastSupportedAt: now.addingTimeInterval(-10 * 365 * 86_400),
            now: now
        )
        expect(HoloMemoryRecallPolicy.isEligible(permanentOld, now: now),
               "永久事实不得因自然时间退出召回")

        let compaction = HoloMemoryCompactionService().plan(
            records: [confirmedStale, permanentOld],
            tombstones: [],
            now: now
        )
        expect(compaction.archiveRecordIDs.contains(confirmedStale.id),
               "用户确认过的阶段状态过时后仍应归档")
        expect(!compaction.archiveRecordIDs.contains(permanentOld.id),
               "永久事实不得因自然时间归档")

        print("HoloMemoryActivationPolicyStandaloneTests passed: \(assertions) assertions")
    }

    private static func makeRecord(
        domain: HoloMemoryDomain,
        claimKind: HoloMemoryClaimKind = .recurringPattern,
        persistenceClass: HoloMemoryPersistenceClass = .phase,
        sensitivity: HoloMemorySensitivity = .normal,
        lastSupportedAt: Date? = nil,
        now: Date
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "policy-\(domain.rawValue)-\(claimKind.rawValue)")
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(domain.rawValue)-\(claimKind.rawValue)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: "lineage-\(domain.rawValue)-\(claimKind.rawValue)",
            revisionDigest: "rev-1",
            observedAt: lastSupportedAt ?? now,
            sampleCount: 3
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
            persistenceClass: persistenceClass,
            displaySummary: "测试记忆",
            aiUseSummary: "测试记忆",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: lastSupportedAt ?? now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: sensitivity,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now
        )
    }

    private static func makeCrossDomainRecord(now: Date) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .goal, value: "reduce-weight")
        let evidence = [HoloMemoryDomain.finance, .habit].map { domain in
            HoloMemoryEvidenceRef(
                id: "evidence-\(domain.rawValue)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "lineage-\(domain.rawValue)",
                revisionDigest: "rev-1",
                observedAt: now,
                sampleCount: 3
            )
        }
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.finance, .habit],
            claimKind: .association,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.finance, .habit],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .association,
            persistenceClass: .phase,
            displaySummary: "跨域测试记忆",
            aiUseSummary: "跨域测试记忆",
            prohibitedInferences: [],
            evidenceRefs: evidence,
            upstreamMemoryIDs: ["finance-memory", "habit-memory"],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
