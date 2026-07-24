import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryMigrationStandaloneTests.main()
    }
}
#endif
struct HoloMemoryMigrationStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    private static func legacyEvidence(_ id: String) -> HoloLongTermMemoryEvidence {
        HoloLongTermMemoryEvidence(
            id: id,
            source: .habits,
            sourceID: "habit-record-\(id)",
            excerpt: "跑步记录 \(id)",
            observedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private static func longTerm(
        id: String,
        state: HoloMemoryConfirmationState
    ) -> HoloLongTermMemory {
        HoloLongTermMemory(
            id: id,
            subjectKey: "habit:running:\(id)",
            title: "跑步节奏",
            confidence: .high,
            confirmationState: state,
            sensitivity: .normal,
            evidence: [legacyEvidence("e1"), legacyEvidence("e2")],
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            expiresAt: nil,
            semanticType: .stablePattern,
            displaySummary: "最近持续跑步",
            aiUseSummary: "用户最近持续跑步",
            useScopes: [.coreContext, .recentInsight],
            prohibitedInferences: ["不要推断为强制偏好"]
        )
    }

    private static func episodic() -> HoloEpisodicMemory {
        HoloEpisodicMemory(
            id: "episodic-1",
            title: "工作日任务较集中",
            summary: "近期工作日任务较集中",
            state: .active,
            visibility: .hidden,
            confidence: .medium,
            sensitivity: .normal,
            hitCount: 3,
            semanticHitRunIDs: ["run-1"],
            evidence: [HoloLongTermMemoryEvidence(
                id: "task-e1",
                source: .tasks,
                sourceID: "task-1",
                excerpt: "任务记录",
                observedAt: Date(timeIntervalSince1970: 1_720_000_000)
            )],
            createdAt: Date(timeIntervalSince1970: 1_715_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000),
            lastHitAt: Date(timeIntervalSince1970: 1_720_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_730_000_000),
            sourceModules: [.tasks],
            reasoningSummary: "多次出现",
            userEditedSummary: nil,
            promotedLongTermMemoryID: nil,
            createdFromRunID: "run-1"
        )
    }

    static func main() async throws {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        let repository = CoreDataHoloMemoryRepository(controller: controller)
        let defaultsName = "holo.memory.migration.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            fatalError("无法创建测试 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-memory-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }

        let snapshot = HoloLegacyMemorySnapshot(
            longTermMemories: [
                longTerm(id: "legacy-candidate", state: .candidate),
                longTerm(id: "legacy-active", state: .confirmed),
                longTerm(id: "legacy-rejected", state: .rejected)
            ],
            episodicMemories: [episodic()],
            suppressionRules: [HoloMemorySuppressionRule(
                id: "suppression-1",
                originalMemorySummary: "这段原文绝不能进入墓碑",
                keywordGroups: [["熬夜", "外卖"]],
                suppressedUntil: Date(timeIntervalSince1970: 1_800_000_000),
                originalRejectedAt: Date(timeIntervalSince1970: 1_720_000_000)
            )]
        )
        let originalSnapshot = snapshot
        let stateStore = UserDefaultsHoloMemoryMigrationStateStore(
            defaults: defaults,
            key: "migration-version"
        )
        let service = HoloMemoryMigrationService(
            repository: repository,
            stateStore: stateStore,
            journalURL: journalDirectory.appendingPathComponent("journal.json"),
            allowDestructiveRerun: false
        )

        let preview = try service.dryRun(snapshot: snapshot)
        expect(preview.records.count == 3,
               "历史候选、有效长期记忆和有效情景记忆都必须映射到统一 record")
        expect(preview.tombstones.count == 2,
               "rejected 与 suppression 必须迁移为墓碑")
        expect(preview.tombstones.allSatisfy { !$0.anchorKeys.joined().contains("这段原文") },
               "墓碑不得保留 suppression 原文")
        expect(preview.records.contains {
            $0.prohibitedInferences.contains("不要推断为强制偏好") && $0.evidenceRefs.count == 2
        }, "迁移不能丢失证据和禁止推断")
        expect(snapshot == originalSnapshot, "dry-run 不能修改旧 JSON 快照")

        var existingCandidate = try require(
            preview.records.first,
            "迁移预览缺少测试记录"
        )
        let existingCreatedAt = Date(timeIntervalSince1970: 1_650_000_000)
        let existingSupportedAt = Date(timeIntervalSince1970: 1_660_000_000)
        let existingAnchor = try HoloMemoryAnchorRef(type: .userTheme, value: "existing-candidate")
        existingCandidate.anchorRefs = [existingAnchor]
        existingCandidate.subjectKey = existingAnchor.stableKey
        existingCandidate.id = try HoloMemoryIdentity.makeStableID(for: existingCandidate)
        existingCandidate.state = .candidate
        existingCandidate.userDecision = .none
        existingCandidate.adoptionMetadata = nil
        existingCandidate.createdAt = existingCreatedAt
        existingCandidate.lastSupportedAt = existingSupportedAt
        existingCandidate.updatedAt = existingSupportedAt
        existingCandidate.scoreComputedAt = existingSupportedAt
        _ = try await repository.upsert(existingCandidate, observationKey: nil)

        let committed = try await service.commit(preview)
        expect(committed == .committed(recordCount: 4, tombstoneCount: 2),
               "迁移提交结果不符合预期")
        expect(stateStore.completedVersion == HoloMemoryMigrationService.currentVersion,
               "成功校验后才允许标记迁移完成")
        let migratedRecords = try await repository.query(.all)
        expect(migratedRecords.count == 4,
               "提交后统一 Repository 应包含迁移记录")
        let migratedExisting = try require(
            migratedRecords.first(where: { $0.id == existingCandidate.id }),
            "统一仓库中的历史候选没有被迁移"
        )
        expect(migratedExisting.state == .active && migratedExisting.userDecision == .none,
               "统一仓库历史候选应解除确认门槛")
        expect(migratedExisting.createdAt == existingCreatedAt &&
               migratedExisting.lastSupportedAt == existingSupportedAt,
               "历史候选迁移必须保留原始时间")
        expect(migratedExisting.adoptionMetadata?.disposition == .historicalMigration,
               "历史候选迁移必须留下采用来源")

        let repeated = try await service.commit(preview)
        expect(repeated == .alreadyCompleted,
               "迁移多次执行必须幂等")

        do {
            _ = try service.dryRun(snapshot: snapshot, force: true)
            fatalError("Release 策略不得允许破坏性重跑")
        } catch HoloMemoryMigrationError.destructiveRerunNotAllowed {
            assertionCount += 1
        }

        try await service.rollback()
        let recordsAfterRollback = try await repository.query(.all)
        expect(recordsAfterRollback == [existingCandidate],
               "回滚必须恢复迁移前的历史候选状态")
        expect(stateStore.completedVersion == 0,
               "回滚后迁移完成标记必须清除")
        expect(snapshot == originalSnapshot,
               "迁移提交和回滚都不能删除旧 JSON 输入")

        let debugService = HoloMemoryMigrationService(
            repository: repository,
            stateStore: stateStore,
            journalURL: journalDirectory.appendingPathComponent("debug-journal.json"),
            allowDestructiveRerun: true
        )
        _ = try debugService.dryRun(snapshot: snapshot, force: true)
        expect(true, "Debug 应允许开发者重新 dry-run")

        print("HoloMemoryMigrationStandaloneTests passed: \(assertionCount) assertions")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }
}
