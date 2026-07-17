import Foundation

final class MockCandidateReconcileRepository: HoloMemoryRepository, @unchecked Sendable {
    var records: [String: HoloMemoryRecord] = [:]

    func upsert(
        _ record: HoloMemoryRecord,
        observationKey: String?
    ) async throws -> HoloMemoryUpsertResult {
        let existed = records[record.id] != nil
        records[record.id] = record
        return existed ? .updated : .inserted
    }

    func hasSuccessfulObservation(_ key: String) async throws -> Bool { false }

    func applyObservationBatch(
        _ records: [HoloMemoryRecord],
        observationKey: String,
        domain: HoloMemoryDomain,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date
    ) async throws -> [HoloMemoryUpsertResult] { [] }

    func fetch(id: String) async throws -> HoloMemoryRecord? { records[id] }

    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        switch query {
        case .all: return Array(records.values)
        case .active: return records.values.filter { $0.state == .active }
        case .domain(let domain): return records.values.filter { $0.primaryDomain == domain }
        }
    }

    func markUserDecision(id: String, decision: HoloMemoryUserDecision, now: Date) async throws -> Bool { false }
    func supersede(id: String, replacementVersionID: String, now: Date) async throws -> Bool { false }
    func storageCounts() async throws -> HoloMemoryStorageCounts {
        HoloMemoryStorageCounts(mainRecords: records.count, sensitiveRecords: 0)
    }
    func loadControlState() async throws -> HoloMemoryControlState { .initial() }
    func saveControlState(_ state: HoloMemoryControlState) async throws {}
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {}
    func fetchTombstone(identityKey: String) async throws -> HoloMemoryTombstone? { nil }
    func queryTombstones() async throws -> [HoloMemoryTombstone] { [] }
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }
    func replaceRecordForMigration(_ record: HoloMemoryRecord) async throws {
        records[record.id] = record
    }
    func hardDeleteRecordForMigration(id: String) async throws {
        records.removeValue(forKey: id)
    }
    func deleteTombstoneForMigration(identityKey: String) async throws {}
}

@main
struct HoloMemoryCandidateReconcilerStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let suiteName = "HoloMemoryCandidateReconcilerStandaloneTests"
        let defaults = try require(UserDefaults(suiteName: suiteName), "无法创建隔离 UserDefaults")
        defaults.removePersistentDomain(forName: suiteName)

        let repository = MockCandidateReconcileRepository()

        // 健康一刀切时代被误标敏感的候选
        var mislabeled = try makeRecord(domain: .health, state: .candidate, now: now)
        mislabeled.sensitivity = .sensitive
        mislabeled.adoptionMetadata = HoloMemoryAdoptionMetadata(
            policyVersion: 1,
            disposition: .pendingConfirmation,
            reason: .sensitiveMemory,
            evaluatedAt: now
        )
        repository.records[mislabeled.id] = mislabeled

        // 因身份规则待确认的候选（重评估后应继续待确认）
        var profilePending = try makeRecord(domain: .profile, state: .candidate, now: now)
        profilePending.adoptionMetadata = HoloMemoryAdoptionMetadata(
            policyVersion: 1,
            disposition: .pendingConfirmation,
            reason: .profileOrIdentity,
            evaluatedAt: now
        )
        repository.records[profilePending.id] = profilePending

        // 用户已确认的记录不动
        var userConfirmed = try makeRecord(domain: .habit, state: .candidate, now: now)
        userConfirmed.userDecision = .confirmed
        repository.records[userConfirmed.id] = userConfirmed

        // 已生效记录不动
        let active = try makeRecord(domain: .finance, state: .active, now: now)
        repository.records[active.id] = active

        let result = try await HoloMemoryCandidateReconciler.reconcileIfNeeded(
            repository: repository,
            defaults: defaults,
            now: now
        )

        expect(result?.reevaluatedCount == 2, "误标与身份候选共 2 条应被重评估")
        expect(result?.activatedCount == 1, "仅误标健康候选应被激活")

        let reactivated = try await repository.fetch(id: mislabeled.id)
        expect(reactivated?.state == .active, "误标健康候选重评估后必须生效")
        expect(reactivated?.sensitivity == .normal, "误标敏感度必须被修正")
        expect(
            reactivated?.recordVersion == mislabeled.recordVersion + 1 &&
                reactivated?.predecessorVersionID == mislabeled.versionID,
            "重评估必须推进版本并保留 predecessor"
        )
        expect(
            reactivated?.adoptionMetadata?.disposition == .automatic,
            "重评估生效的记录必须标记为自动采用"
        )

        let stillPending = try await repository.fetch(id: profilePending.id)
        expect(stillPending?.state == .candidate, "身份候选重评估后必须继续待确认")
        expect(
            stillPending?.adoptionMetadata?.policyVersion == HoloMemoryActivationPolicy.currentVersion,
            "重评估必须刷新策略版本号"
        )

        let untouchedConfirmed = try await repository.fetch(id: userConfirmed.id)
        expect(
            untouchedConfirmed?.userDecision == .confirmed &&
                untouchedConfirmed?.recordVersion == userConfirmed.recordVersion,
            "用户已表态的记录不得被重评估改动"
        )

        let untouchedActive = try await repository.fetch(id: active.id)
        expect(
            untouchedActive?.recordVersion == active.recordVersion,
            "已生效记录不得被重评估改动"
        )

        let secondRun = try await HoloMemoryCandidateReconciler.reconcileIfNeeded(
            repository: repository,
            defaults: defaults,
            now: now
        )
        expect(secondRun == nil, "同一策略版本不得重复重评估")

        print("HoloMemoryCandidateReconcilerStandaloneTests passed: \(assertions) assertions")
    }

    private static func makeRecord(
        domain: HoloMemoryDomain,
        state: HoloMemoryState,
        now: Date
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "reconcile-\(domain.rawValue)")
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(domain.rawValue)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: "lineage-\(domain.rawValue)",
            revisionDigest: "rev-1",
            observedAt: now,
            sampleCount: 3
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "测试记忆",
            aiUseSummary: "测试记忆",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }
}
