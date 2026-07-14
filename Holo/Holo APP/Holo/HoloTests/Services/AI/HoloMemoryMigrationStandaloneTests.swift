import Foundation

@main
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
            subjectKey: "habit:running",
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
        expect(preview.records.count == 2,
               "有效长期记忆和有效情景记忆都必须映射到统一 record")
        expect(preview.tombstones.count == 2,
               "rejected 与 suppression 必须迁移为墓碑")
        expect(preview.tombstones.allSatisfy { !$0.anchorKeys.joined().contains("这段原文") },
               "墓碑不得保留 suppression 原文")
        expect(preview.records.contains {
            $0.prohibitedInferences.contains("不要推断为强制偏好") && $0.evidenceRefs.count == 2
        }, "迁移不能丢失证据和禁止推断")
        expect(snapshot == originalSnapshot, "dry-run 不能修改旧 JSON 快照")

        let committed = try await service.commit(preview)
        expect(committed == .committed(recordCount: 2, tombstoneCount: 2),
               "迁移提交结果不符合预期")
        expect(stateStore.completedVersion == HoloMemoryMigrationService.currentVersion,
               "成功校验后才允许标记迁移完成")
        let migratedRecords = try await repository.query(.all)
        expect(migratedRecords.count == 2,
               "提交后统一 Repository 应包含迁移记录")

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
        expect(recordsAfterRollback.isEmpty,
               "回滚必须恢复迁移前 Repository")
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
}
