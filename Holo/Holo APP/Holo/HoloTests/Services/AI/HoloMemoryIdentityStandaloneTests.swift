import Foundation

@main
struct HoloMemoryIdentityStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        let goal = try HoloMemoryAnchorRef(type: .goal, value: "A3E57DC4-3A5B-4BA2-BDA8-2CC8B07A9287")
        let habit = try HoloMemoryAnchorRef(type: .habit, value: "running-habit")
        let duplicateGoal = try HoloMemoryAnchorRef(type: .goal, value: "a3e57dc4-3a5b-4ba2-bda8-2cc8b07a9287")

        let canonicalAnchors = HoloMemoryIdentity.canonicalAnchors(
            [habit, goal, duplicateGoal]
        )
        expect(canonicalAnchors.count == 2, "类型化 anchor 必须稳定去重")
        expect(canonicalAnchors.map(\.stableKey) == canonicalAnchors.map(\.stableKey).sorted(),
               "类型化 anchor 必须稳定排序")

        let firstID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [habit, goal]
        )
        let secondID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [goal, habit, duplicateGoal]
        )
        expect(firstID == secondID, "anchor 顺序或重复项不能改变稳定 ID")

        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-1",
            kind: .entityRef,
            sourceDomain: .habit,
            lineageKey: "habit-event-1",
            sourceID: "habit-record-1",
            revisionDigest: "revision-v1",
            observedAt: now
        )
        let base = HoloMemoryRecord(
            id: firstID,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: "减肥",
            anchorRefs: [habit, goal],
            claimKind: .recurringPattern,
            persistenceClass: .durable,
            displaySummary: "最近保持跑步",
            aiUseSummary: "用户近期保持跑步节奏",
            prohibitedInferences: ["不要推断人格"],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.8,
            freshnessScore: 0.9,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
        try base.validate()

        var synonymous = base
        synonymous.subjectKey = "体重管理"
        synonymous.displaySummary = "2026-07-14 报告 card-99：跑步节奏稳定"
        synonymous.lastObservationKey = "report-2026-07-14-card-99"
        synonymous.id = try HoloMemoryIdentity.makeStableID(for: synonymous)
        expect(synonymous.id == base.id,
               "同义 subjectKey、日期、报告 ID 和卡片 ID 不能改变稳定 ID")

        var registry = HoloMemoryAnchorRegistry()
        let alias = HoloMemoryAnchorAliasCandidate(
            alias: "减肥",
            suggestedAnchor: goal,
            proposedBy: .model
        )
        registry.propose(alias)
        expect(registry.resolve("减肥", type: .goal) == nil,
               "未验证 alias 只能作为候选，不能直接创建 canonical anchor")
        registry.confirm(alias, confirmedBy: .localEntityMatch)
        expect(registry.resolve("减肥", type: .goal) == goal,
               "本地实体匹配确认后 alias 才能解析到 canonical anchor")

        var invalidDomain = base
        invalidDomain.sourceDomains = [.habit, .finance]
        expectThrows("领域记忆只能有一个 primaryDomain") {
            try invalidDomain.validate()
        }

        var invalidCrossDomain = base
        invalidCrossDomain.scope = .crossDomain
        invalidCrossDomain.primaryDomain = nil
        invalidCrossDomain.sourceDomains = [.habit]
        invalidCrossDomain.upstreamMemoryIDs = ["memory-a"]
        expectThrows("跨域记忆至少需要两个 sourceDomains") {
            try invalidCrossDomain.validate()
        }

        var validCrossDomain = invalidCrossDomain
        validCrossDomain.sourceDomains = [.habit, .finance]
        validCrossDomain.upstreamMemoryIDs = ["memory-a", "memory-b"]
        validCrossDomain.id = try HoloMemoryIdentity.makeStableID(for: validCrossDomain)
        try validCrossDomain.validate()

        print("HoloMemoryIdentityStandaloneTests passed: \(assertionCount) assertions")
    }

    private static func expectThrows(
        _ message: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError(message)
        } catch {
            assertionCount += 1
        }
    }
}
