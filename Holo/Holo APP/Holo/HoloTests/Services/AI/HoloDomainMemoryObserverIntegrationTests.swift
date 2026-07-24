import Foundation

actor FakeDomainMemoryClient: HoloDomainMemoryLLMClient {
    var calls: [HoloMemoryDomain: Int] = [:]
    var failingDomains: Set<HoloMemoryDomain> = [.health]
    var invalidDomains: Set<HoloMemoryDomain> = [.finance]

    func extract(
        request: HoloDomainObservationRequest,
        domain: HoloMemoryDomain
    ) async throws -> Data {
        calls[domain, default: 0] += 1
        if failingDomains.contains(domain) { throw TestError.expected }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(
            HoloDomainObservationPackage.self,
            from: Data(request.userDataJSON.utf8)
        )
        guard let signal = package.signals.first else {
            return try JSONEncoder().encode(HoloDomainMemoryOutputEnvelope(candidates: []))
        }
        let candidate = HoloDomainMemoryCandidateOutput(
            domain: domain,
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "\(domain.rawValue) 的阶段模式",
            aiUseSummary: "用户近期存在 \(domain.rawValue) 阶段模式",
            anchors: signal.anchors,
            evidenceIDs: invalidDomains.contains(domain) ? ["forged"] : [signal.evidence.id],
            prohibitedInferences: signal.prohibitedInferences
        )
        return try JSONEncoder().encode(HoloDomainMemoryOutputEnvelope(candidates: [candidate]))
    }

    func callCount(_ domain: HoloMemoryDomain) -> Int { calls[domain, default: 0] }

    enum TestError: Error { case expected }
}

actor FakeDomainMemoryStore: HoloDomainMemoryObservationStore {
    var successfulKeys = Set<String>()
    var records: [String: HoloMemoryRecord] = [:]
    var tombstonedIDs = Set<String>()

    func hasSuccessfulObservation(_ key: String) async throws -> Bool {
        successfulKeys.contains(key)
    }

    func applyObservationBatch(
        _ incoming: [HoloMemoryRecord],
        observationKey: String,
        domain: HoloMemoryDomain,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date
    ) async throws -> [HoloMemoryUpsertResult] {
        let results = incoming.map { record -> HoloMemoryUpsertResult in
            if tombstonedIDs.contains(record.id) { return .rejectedByTombstone }
            records[record.id] = record
            return .inserted
        }
        successfulKeys.insert(observationKey)
        return results
    }

    func snapshot() -> ([HoloMemoryRecord], Set<String>) {
        (Array(records.values), successfulKeys)
    }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloDomainMemoryObserverIntegrationTests.main()
    }
}
#endif
struct HoloDomainMemoryObserverIntegrationTests {
    private static var assertions = 0

    static func main() async throws {
        let client = FakeDomainMemoryClient()
        let store = FakeDomainMemoryStore()
        let executor = HoloDomainMemoryObserverExecutor(
            client: client,
            storeProvider: { store },
            accessProvider: { true }
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let inputs = try [
            makeRun(domain: .finance, key: "finance-run", now: now),
            makeRun(domain: .habit, key: "habit-run", now: now),
            makeRun(domain: .health, key: "health-run", now: now),
            makeRun(domain: .goal, key: "goal-run", now: now)
        ]
        let results = await executor.run(inputs, now: now)

        expect(results.contains(.rejected(domain: .finance, count: 1)),
               "伪造 evidence 的领域结果必须整体拒绝")
        expect(results.contains(.succeeded(domain: .habit, writtenCount: 1)),
               "合法领域结果应写入统一 Repository")
        expect(results.contains(.failed(domain: .health)),
               "单个领域网络失败应被隔离")
        expect(results.contains(.succeeded(domain: .goal, writtenCount: 1)),
               "前一领域失败不得阻止后一领域完成")

        var snapshot = await store.snapshot()
        expect(Set(snapshot.0.compactMap(\.primaryDomain)) == Set([.habit, .goal]),
               "Validator 拒绝时不得留下半成品")
        expect(!snapshot.1.contains("finance-run") && snapshot.1.contains("habit-run"),
               "只有完整提交成功的 observation key 才能标记成功")

        let rerun = await executor.run([inputs[1]], now: now.addingTimeInterval(10))
        expect(rerun == [.skippedDuplicate(domain: .habit)],
               "已成功 observation key 不得重复发网络请求")
        let habitCallCount = await client.callCount(.habit)
        expect(habitCallCount == 1,
               "幂等跳过必须发生在网络请求之前")

        try testCounterEvidenceAndSupersede(now: now, existing: snapshot.0.first {
            $0.primaryDomain == .habit
        }!)
        snapshot = await store.snapshot()
        expect(snapshot.0.count == 2, "独立领域成功结果应分别持久化")

        print("HoloDomainMemoryObserverIntegrationTests: \(assertions) assertions passed")
    }

    private static func testCounterEvidenceAndSupersede(
        now: Date,
        existing: HoloMemoryRecord
    ) throws {
        let oldAnchor = existing.anchorRefs[0]
        let replacementAnchor = try HoloMemoryAnchorRef(type: .userTheme, value: "habit-replacement")
        let oldSignal = try makeSignal(
            domain: .habit,
            id: "counter-signal",
            anchor: oldAnchor,
            now: now.addingTimeInterval(20)
        )
        let replacementSignal = try makeSignal(
            domain: .habit,
            id: "replacement-signal",
            anchor: replacementAnchor,
            now: now.addingTimeInterval(20)
        )
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .habit,
            window: .init(start: now, end: now.addingTimeInterval(30)),
            signals: [oldSignal, replacementSignal],
            existingMemories: [existing]
        )
        let replacement = HoloDomainMemoryCandidateOutput(
            domain: .habit,
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "新的习惯阶段",
            aiUseSummary: "用户进入新的习惯阶段",
            anchors: [replacementAnchor],
            evidenceIDs: [replacementSignal.evidence.id],
            prohibitedInferences: []
        )
        let replacementID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [replacementAnchor]
        )
        let result = HoloDomainMemoryOutputValidator.validate(
            envelope: .init(
                candidates: [replacement],
                counterEvidence: [.init(
                    memoryID: existing.id,
                    evidenceIDs: [oldSignal.evidence.id]
                )],
                supersedes: [.init(
                    memoryID: existing.id,
                    replacementMemoryID: replacementID
                )]
            ),
            against: package,
            now: now.addingTimeInterval(30),
            extractorVersion: 1,
            promptVersion: 1
        )
        expect(result.rejections.isEmpty, "合法 counter-evidence 与 supersede 操作应通过")
        let updated = result.validRecords.first { $0.id == existing.id }
        expect(updated?.counterEvidenceRefs.count == 1 && updated?.state == .superseded,
               "反例和替代必须通过统一生命周期状态机处理")
    }

    private static func makeRun(
        domain: HoloMemoryDomain,
        key: String,
        now: Date
    ) throws -> HoloDomainObservationRunInput {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "\(domain.rawValue)-theme")
        let signal = try makeSignal(domain: domain, id: "\(domain.rawValue)-signal", anchor: anchor, now: now)
        return HoloDomainObservationRunInput(
            package: HoloDomainObservationPackageBuilder.build(
                domain: domain,
                window: .init(start: now.addingTimeInterval(-86_400), end: now),
                signals: [signal]
            ),
            observationKey: key,
            extractorVersion: 1,
            promptVersion: 1
        )
    }

    private static func makeSignal(
        domain: HoloMemoryDomain,
        id: String,
        anchor: HoloMemoryAnchorRef,
        now: Date
    ) throws -> HoloDomainMemorySignal {
        try HoloDomainSignalBuilder.make(
            id: id,
            domain: domain,
            kind: .aggregate,
            evidence: .init(
                id: "evidence-\(id)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "lineage-\(id)",
                revisionDigest: "revision-\(id)",
                observedAt: now
            ),
            anchors: [anchor]
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }
}
