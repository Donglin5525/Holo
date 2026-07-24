import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloMemoryLiveObservationPlanStandaloneTests.main()
    }
}
#endif
struct HoloMemoryLiveObservationPlanStandaloneTests {
    private static var assertions = 0

    static func main() throws {
        let finance = try signal(id: "finance-a", domain: .finance, revision: "r1")
        let financeR2 = try signal(id: "finance-a", domain: .finance, revision: "r2")
        let health = try signal(id: "health-a", domain: .health, revision: "r1")
        let financeDigest = HoloMemoryLiveObservationPlan.signalDigest([finance])
        var financeObservedLater = finance
        financeObservedLater.evidence.observedAt = finance.evidence.observedAt.addingTimeInterval(3_600)
        financeObservedLater.evidence.validFrom = finance.evidence.observedAt.addingTimeInterval(-86_400)
        financeObservedLater.evidence.validTo = finance.evidence.observedAt.addingTimeInterval(3_600)

        expect(!financeDigest.isEmpty, "非空信号必须生成稳定摘要")
        expect(
            financeDigest == HoloMemoryLiveObservationPlan.signalDigest([finance]),
            "同一信号摘要必须幂等"
        )
        expect(
            financeDigest != HoloMemoryLiveObservationPlan.signalDigest([
                financeR2
            ]),
            "证据修订变化必须触发新摘要"
        )
        expect(
            financeDigest == HoloMemoryLiveObservationPlan.signalDigest([financeObservedLater]),
            "仅观察时间或滚动窗口变化时不得重复标脏和重复付费"
        )

        let initial = HoloMemoryLiveObservationPlan.changedDomainDigests(
            signalsByDomain: [.finance: [finance], .health: [health], .profile: []],
            previous: [:]
        )
        expect(initial.count == 2, "首次运行应标记所有非空领域")
        expect(initial[.profile] == nil, "空 Profile 不得触发外部 AI")

        let unchanged = HoloMemoryLiveObservationPlan.changedDomainDigests(
            signalsByDomain: [.finance: [finance], .health: [health]],
            previous: [
                HoloMemoryDomain.finance.rawValue: initial[.finance]!,
                HoloMemoryDomain.health.rawValue: initial[.health]!
            ]
        )
        expect(unchanged.isEmpty, "快照不变不得重复标脏和重复付费")

        let oneChanged = HoloMemoryLiveObservationPlan.changedDomainDigests(
            signalsByDomain: [
                .finance: [financeR2],
                .health: [health]
            ],
            previous: [
                HoloMemoryDomain.finance.rawValue: initial[.finance]!,
                HoloMemoryDomain.health.rawValue: initial[.health]!
            ]
        )
        expect(Set(oneChanged.keys) == [.finance], "单域变化不得污染其他模块")
        expect(
            HoloMemoryLiveObservationPlan.crossDomainDigest([]) ==
                HoloMemoryLiveObservationPlan.crossDomainDigest([]),
            "跨域候选摘要必须稳定"
        )
        print("HoloMemoryLiveObservationPlanStandaloneTests: \(assertions) assertions passed")
    }

    private static func signal(
        id: String,
        domain: HoloMemoryDomain,
        revision: String
    ) throws -> HoloDomainMemorySignal {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "current-routine")
        let evidence = HoloMemoryEvidenceRef(
            id: "e-\(id)-\(revision)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: "lineage-\(id)",
            revisionDigest: revision,
            observedAt: Date(timeIntervalSince1970: 1_752_595_200),
            sampleCount: 7
        )
        return try HoloDomainSignalBuilder.make(
            id: id,
            domain: domain,
            kind: .aggregate,
            evidence: evidence,
            anchors: [anchor],
            numericFacts: ["count": 7]
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError("断言失败：\(message)") }
    }
}
