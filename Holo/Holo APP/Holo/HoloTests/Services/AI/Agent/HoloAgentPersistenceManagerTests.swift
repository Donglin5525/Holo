//
//  HoloAgentPersistenceManagerTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.4 Persistence Manager 测试
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/"*.swift \
//    "Holo/Services/AI/Agent/Persistence/"*.swift \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    <本测试> -o /tmp/holo_agent_manager_test && /tmp/holo_agent_manager_test
//

import Foundation

/// 内存版 Evidence Ledger，用于隔离测试（真实 `HoloEvidenceLedger` 在 Phase 2 实现）。
/// 非 throwing 实现仍满足 throws 协议要求（§5.5）。
actor MockEvidenceLedger: HoloEvidenceLedgerProtocol {
    private var records: [HoloEvidenceRecord] = []

    func load() -> [HoloEvidenceRecord] { records }

    func upsert(_ newRecords: [HoloEvidenceRecord]) {
        for record in newRecords {
            if let index = records.firstIndex(where: { $0.dedupeKey == record.dedupeKey }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }
    }
}

@main
struct HoloAgentPersistenceManagerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testSaveProgress_写入Evidence与Checkpoint与Job()
        try await testValidateCheckpoint_引用不存在Evidence返回false()
        try await testCleanupOrphanedEvidence_超过保留期被归档()
        print("HoloAgentPersistenceManagerTests passed")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-manager-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeJob(id: String, state: HoloAgentJobState, updatedAt: Date) -> HoloAgentJob {
        HoloAgentJob(
            id: id, type: .deepAnalysis, userQuestion: "测试",
            trigger: .userQuestion, state: state, currentStep: .plan,
            createdAt: Date(timeIntervalSince1970: 1000), updatedAt: updatedAt,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: updatedAt),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
    }

    private static func makeCheckpoint(id: String, jobID: String, updatedAt: Date) -> HoloAgentCheckpoint {
        HoloAgentCheckpoint(
            id: id, jobID: jobID, step: .plan, completedSteps: [],
            conversationState: [], pendingToolRequests: [], completedToolResults: [],
            patternSignals: [], evidenceRecordIDs: [], validatedClaimIDs: [],
            memoryCandidateIDs: [], retryCountByStep: [:],
            createdAt: Date(timeIntervalSince1970: 1000), updatedAt: updatedAt
        )
    }

    private static func makeEvidence(id: String, status: HoloEvidenceStatus, generatedAt: Date) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: .habit, sourceID: "src", sourceKind: "kind",
            timeRange: nil, occurredAt: generatedAt, metricKey: "metric", metricValue: 1, unit: "次",
            baselineValue: nil, comparison: nil, excerpt: "原文", redactedExcerpt: "脱敏",
            sensitivity: .normal, confidence: 1.0, status: status,
            generatedBy: "test", generatedAt: generatedAt,
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func makeManager(
        ledger: MockEvidenceLedger,
        dir: URL
    ) -> HoloAgentPersistenceManager {
        HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: HoloAgentCheckpointStore(directory: dir),
            jobStore: HoloAgentJobStore(directory: dir),
            resultStore: HoloAgentResultStore(directory: dir)
        )
    }

    // MARK: - 用例

    private static func testSaveProgress_写入Evidence与Checkpoint与Job() async throws {
        let dir = makeTempDir()
        let ledger = MockEvidenceLedger()
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let jobStore = HoloAgentJobStore(directory: dir)
        let manager = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: HoloAgentResultStore(directory: dir)
        )

        let now = Date(timeIntervalSince1970: 1000)
        try await manager.saveProgress(
            job: makeJob(id: "job-1", state: .running, updatedAt: now),
            evidence: [makeEvidence(id: "ev-1", status: .active, generatedAt: now)],
            checkpoint: makeCheckpoint(id: "cp-1", jobID: "job-1", updatedAt: now)
        )

        let evidence = await ledger.load()
        expect(evidence.contains { $0.id == "ev-1" }, "evidence 应写入 ledger")

        let savedCheckpoint = try await checkpointStore.latestForJob(jobID: "job-1")
        expect(savedCheckpoint?.id == "cp-1", "checkpoint 应写入 store")

        let savedJob = try await jobStore.load().first { $0.id == "job-1" }
        expect(savedJob?.state == .running, "job 应写入 store 且状态正确")
    }

    private static func testValidateCheckpoint_引用不存在Evidence返回false() async throws {
        let dir = makeTempDir()
        let ledger = MockEvidenceLedger()
        await ledger.upsert([makeEvidence(id: "ev-1", status: .active, generatedAt: Date(timeIntervalSince1970: 1000))])
        let manager = makeManager(ledger: ledger, dir: dir)

        var cpWithMissing = makeCheckpoint(id: "cp-x", jobID: "job-x", updatedAt: Date(timeIntervalSince1970: 1000))
        cpWithMissing.evidenceRecordIDs = ["ev-1", "ev-missing"]
        let invalid = try await manager.validateCheckpoint(cpWithMissing)
        expect(!invalid, "引用不存在的 ev-missing 应返回 false")

        var cpValid = makeCheckpoint(id: "cp-y", jobID: "job-y", updatedAt: Date(timeIntervalSince1970: 1000))
        cpValid.evidenceRecordIDs = ["ev-1"]
        let valid = try await manager.validateCheckpoint(cpValid)
        expect(valid, "只引用存在的 ev-1 应返回 true")
    }

    private static func testCleanupOrphanedEvidence_超过保留期被归档() async throws {
        let dir = makeTempDir()
        let ledger = MockEvidenceLedger()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400
        await ledger.upsert([
            makeEvidence(id: "ev-old", status: .orphaned, generatedAt: now.addingTimeInterval(-8 * day)),
            makeEvidence(id: "ev-fresh", status: .orphaned, generatedAt: now.addingTimeInterval(-1 * day)),
            makeEvidence(id: "ev-active", status: .active, generatedAt: now.addingTimeInterval(-100 * day))
        ])
        let manager = makeManager(ledger: ledger, dir: dir)

        let removed = try await manager.cleanupOrphanedEvidence(now: now, retentionDays: 7)
        expect(removed.count == 1, "只应归档 1 条（ev-old），实际 \(removed.count)")

        let records = await ledger.load()
        let oldStatus = records.first { $0.id == "ev-old" }?.status
        expect(oldStatus == .archived, "ev-old 应被归档为 archived")
        let freshStatus = records.first { $0.id == "ev-fresh" }?.status
        expect(freshStatus == .orphaned, "ev-fresh 未超保留期应保持 orphaned")
    }
}
