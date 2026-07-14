import CoreData
import Foundation

@main
struct HoloMemoryRepositoryIntegrationTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    private static func makeRecord(
        domain: HoloMemoryDomain,
        anchorValue: String,
        evidenceID: String,
        sourceDomain: HoloMemoryDomain? = nil,
        scope: HoloMemoryScope = .domain,
        sourceDomains: [HoloMemoryDomain]? = nil,
        upstreamMemoryIDs: [String] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1_720_000_000)
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: anchorValue)
        let domains = sourceDomains ?? [domain]
        let primary: HoloMemoryDomain? = scope == .domain ? domain : nil
        let id = try HoloMemoryIdentity.makeStableID(
            scope: scope,
            primaryDomain: primary,
            sourceDomains: domains,
            claimKind: scope == .domain ? .recurringPattern : .association,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: scope,
            primaryDomain: primary,
            sourceDomains: domains,
            subjectKey: anchorValue,
            anchorRefs: [anchor],
            claimKind: scope == .domain ? .recurringPattern : .association,
            persistenceClass: .phase,
            displaySummary: "\(anchorValue) 的阶段结论",
            aiUseSummary: "用户近期呈现 \(anchorValue)",
            prohibitedInferences: ["不要推断因果"],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: evidenceID,
                kind: sourceDomain == .health ? .aggregateSnapshot : .entityRef,
                sourceDomain: sourceDomain ?? domain,
                lineageKey: "lineage-\(evidenceID)",
                sourceID: evidenceID,
                revisionDigest: "revision-\(evidenceID)",
                observedAt: updatedAt
            )],
            upstreamMemoryIDs: upstreamMemoryIDs,
            counterEvidenceRefs: [],
            lastSupportedAt: updatedAt,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: updatedAt,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: sourceDomain == .health ? .sensitive : .normal,
            userDecision: .none,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    static func main() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)

        let finance = try makeRecord(
            domain: .finance,
            anchorValue: "monthly-spending",
            evidenceID: "finance-1"
        )
        let health = try makeRecord(
            domain: .health,
            anchorValue: "sleep-trend",
            evidenceID: "health-1",
            sourceDomain: .health
        )
        let crossHealth = try makeRecord(
            domain: .finance,
            anchorValue: "sleep-and-spending",
            evidenceID: "health-cross-1",
            sourceDomain: .health,
            scope: .crossDomain,
            sourceDomains: [.finance, .health],
            upstreamMemoryIDs: [finance.id, health.id]
        )

        let financeInsert = try await repository.upsert(finance, observationKey: "finance-window-v1")
        let healthInsert = try await repository.upsert(health, observationKey: "health-window-v1")
        let crossHealthInsert = try await repository.upsert(
            crossHealth,
            observationKey: "cross-health-window-v1"
        )
        expect(financeInsert == .inserted,
               "普通领域记忆首次写入应成功")
        expect(healthInsert == .inserted,
               "健康记忆首次写入应成功")
        expect(crossHealthInsert == .inserted,
               "含健康 lineage 的跨域记忆首次写入应成功")

        let counts = try await repository.storageCounts()
        expect(counts.mainRecords == 1, "普通领域记忆必须进入主私有 Store")
        expect(counts.sensitiveRecords == 2,
               "健康及含健康 lineage 的跨域记忆必须只进入本机敏感 Store")
        expect(controller.sensitiveStoreHasCloudKitOptions == false,
               "敏感 Store 不得配置 CloudKit")

        let duplicate = try await repository.upsert(finance, observationKey: "finance-window-v1")
        expect(duplicate == .duplicateObservation,
               "成功 observation key 重放不得重复写入")

        var financeWithNewEvidence = finance
        financeWithNewEvidence.evidenceRefs = [HoloMemoryEvidenceRef(
            id: "finance-2",
            kind: .entityRef,
            sourceDomain: .finance,
            lineageKey: "lineage-finance-2",
            sourceID: "finance-2",
            revisionDigest: "revision-finance-2",
            observedAt: finance.updatedAt.addingTimeInterval(1)
        )]
        financeWithNewEvidence.updatedAt = finance.updatedAt.addingTimeInterval(1)
        let newEvidenceSnapshot = financeWithNewEvidence

        async let upsertResult = repository.upsert(
            newEvidenceSnapshot,
            observationKey: "finance-window-v2"
        )
        async let feedbackResult = repository.markUserDecision(
            id: finance.id,
            decision: .confirmed,
            now: finance.updatedAt.addingTimeInterval(2)
        )
        _ = try await (upsertResult, feedbackResult)

        guard let merged = try await repository.fetch(id: finance.id) else {
            fatalError("并发更新后记忆丢失")
        }
        expect(Set(merged.evidenceRefs.map(\.id)) == Set(["finance-1", "finance-2"]),
               "多设备/并发生成必须合并 evidence lineage，不能削弱已有证据")
        expect(merged.userDecision == .confirmed,
               "自动生成不得覆盖更新的用户决定")

        var staleAutomatic = finance
        staleAutomatic.displaySummary = "旧任务试图覆盖用户确认"
        staleAutomatic.updatedAt = finance.updatedAt
        let blocked = try await repository.upsert(
            staleAutomatic,
            observationKey: "finance-stale-auto"
        )
        expect(blocked == .rejectedByNewerUserControl,
               "旧后台结果不得反向覆盖更新的用户决定")

        let beforeInvalid = try await repository.storageCounts()
        var invalid = finance
        invalid.id = "invalid-id"
        do {
            _ = try await repository.upsert(invalid, observationKey: "invalid")
            fatalError("非法 record 必须被拒绝")
        } catch HoloMemoryRepositoryError.invalidRecord {
            assertionCount += 1
        }
        let afterInvalid = try await repository.storageCounts()
        expect(beforeInvalid == afterInvalid, "写入失败必须整体回滚")

        _ = try await repository.supersede(
            id: health.id,
            replacementVersionID: "health-replacement@v2",
            now: Date(timeIntervalSince1970: 1_730_000_000)
        )
        let active = try await repository.query(.active)
        expect(active.allSatisfy { ![.superseded, .deleted, .suppressed, .tombstoned].contains($0.state) },
               "默认查询必须排除不可用正文")

        let diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-memory-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: diskDirectory) }
        do {
            let diskController = try HoloMemoryPersistenceController(directoryURL: diskDirectory)
            let diskRepository = CoreDataHoloMemoryRepository(controller: diskController)
            _ = try await diskRepository.upsert(finance, observationKey: "restart-v1")
        }
        do {
            let reopenedController = try HoloMemoryPersistenceController(directoryURL: diskDirectory)
            let reopenedRepository = CoreDataHoloMemoryRepository(controller: reopenedController)
            let recovered = try await reopenedRepository.fetch(id: finance.id)
            expect(recovered != nil,
                   "Repository 重启后必须恢复已提交记忆")
        }

        print("HoloMemoryRepositoryIntegrationTests passed: \(assertionCount) assertions")
    }
}
