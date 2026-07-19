//
//  HoloAgentConsistencyReconcilerTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 1（§5.4，修 P0-6 收尾）
//  启动一致性修复器 XCTest：
//  - Result 存在、Job 非终态 → 补 completed
//  - Job completed、Result 缺失 → 置 failed（不展示伪完成）
//  - Checkpoint 引用 evidence 缺失 → 置 failed（不得继续生成无证据结论）
//  - 同 job 历史多 Result → 收敛为 generatedAt 最新一条
//

import XCTest
@testable import Holo

final class HoloAgentConsistencyReconcilerTests: XCTestCase {

    /// 内存版 Evidence Ledger（非 throwing 实现仍满足 throws 协议要求）。
    private actor FakeLedger: HoloEvidenceLedgerProtocol {
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

    private struct Fixture {
        let persistence: HoloAgentPersistenceManager
        let jobStore: HoloAgentJobStore
        let checkpointStore: HoloAgentCheckpointStore
        let resultStore: HoloAgentResultStore
        let reconciler: HoloAgentConsistencyReconciler
    }

    private func makeFixture() -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-reconciler-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jobStore = HoloAgentJobStore(directory: dir)
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let resultStore = HoloAgentResultStore(directory: dir)
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: FakeLedger(),
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: resultStore
        )
        return Fixture(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            resultStore: resultStore,
            reconciler: HoloAgentConsistencyReconciler(persistence: persistence)
        )
    }

    private let baseTime = Date(timeIntervalSince1970: 1_000_000)

    private func makeJob(id: String, state: HoloAgentJobState) -> HoloAgentJob {
        HoloAgentJob(
            id: id, type: .deepAnalysis, userQuestion: "测试",
            trigger: .userQuestion, state: state, currentStep: .plan,
            createdAt: baseTime, updatedAt: baseTime,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: baseTime),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
    }

    private func makeResult(id: String, jobID: String, generatedAt: Date) -> HoloAgentResult {
        HoloAgentResult(
            id: id, jobID: jobID, title: "洞察", summary: "摘要 \(id)",
            claims: [], evidenceIDs: [], memoryCandidateIDs: [],
            status: "completed", generatedAt: generatedAt, updatedAt: generatedAt
        )
    }

    private func makeCheckpoint(id: String, jobID: String, evidenceIDs: [String]) -> HoloAgentCheckpoint {
        HoloAgentCheckpoint(
            id: id, jobID: jobID, step: .plan, completedSteps: [],
            conversationState: [], pendingToolRequests: [], completedToolResults: [],
            patternSignals: [], evidenceRecordIDs: evidenceIDs, validatedClaimIDs: [],
            memoryCandidateIDs: [], retryCountByStep: [:],
            createdAt: baseTime, updatedAt: baseTime
        )
    }

    // MARK: - 用例

    /// Result 已落盘、Job 未完成（崩溃发生在 Result 保存后、Job 更新前）→ 启动补成 completed。
    func testReconcile_Result存在Job非终态_补成completed() async throws {
        let fixture = makeFixture()
        try await fixture.jobStore.upsert(makeJob(id: "job-1", state: .running))
        let result = makeResult(id: "agent-result:job-1", jobID: "job-1",
                                generatedAt: baseTime.addingTimeInterval(60))
        try await fixture.resultStore.upsert(result)

        let now = baseTime.addingTimeInterval(3600)
        let report = try await fixture.reconciler.reconcile(now: now)

        XCTAssertEqual(report.jobsCompletedByResult, 1)
        XCTAssertTrue(report.hasFixes)
        let stored = try await fixture.jobStore.load().first { $0.id == "job-1" }
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.resultID, "agent-result:job-1")
        XCTAssertEqual(stored?.updatedAt, now)
    }

    /// Job completed、Result 缺失（崩溃发生在 Result 保存前）→ 置 failed，不展示伪完成。
    func testReconcile_Job完成但Result缺失_置failed() async throws {
        let fixture = makeFixture()
        try await fixture.jobStore.upsert(makeJob(id: "job-2", state: .completed))

        let report = try await fixture.reconciler.reconcile(now: baseTime.addingTimeInterval(3600))

        XCTAssertEqual(report.jobsFailedMissingResult, 1)
        let stored = try await fixture.jobStore.load().first { $0.id == "job-2" }
        XCTAssertEqual(stored?.state, .failed)
        XCTAssertNotNil(stored?.errorSummary, "failed 必须带可解释 errorSummary")
    }

    /// 非终态 Job 的 checkpoint 引用 evidence 缺失 → 置 failed，不得继续生成无证据结论。
    func testReconcile_Checkpoint引用evidence缺失_置failed() async throws {
        let fixture = makeFixture()
        try await fixture.jobStore.upsert(makeJob(id: "job-3", state: .waitingForForeground))
        try await fixture.checkpointStore.upsert(
            makeCheckpoint(id: "cp-3", jobID: "job-3", evidenceIDs: ["ghost-evidence"])
        )

        let report = try await fixture.reconciler.reconcile(now: baseTime.addingTimeInterval(3600))

        XCTAssertEqual(report.jobsFailedMissingEvidence, 1)
        let stored = try await fixture.jobStore.load().first { $0.id == "job-3" }
        XCTAssertEqual(stored?.state, .failed)
        XCTAssertNotNil(stored?.errorSummary)
    }

    /// 同 job 历史多 Result（旧数据）→ 保留 generatedAt 最新一条，其余删除。
    func testReconcile_同job多Result_收敛为最新一条() async throws {
        let fixture = makeFixture()
        try await fixture.jobStore.upsert(makeJob(id: "job-4", state: .completed))
        // 旧数据：同一 job 两条 result（绕过按 jobID 唯一的 upsert，直接写文件模拟历史数据）
        let legacy = [
            makeResult(id: "res-old", jobID: "job-4", generatedAt: baseTime.addingTimeInterval(100)),
            makeResult(id: "agent-result:job-4", jobID: "job-4", generatedAt: baseTime.addingTimeInterval(200))
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-reconciler-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("agentResults.json"))
        // 用独立目录重建 fixture，载入旧数据
        let jobStore = HoloAgentJobStore(directory: dir)
        try await jobStore.upsert(makeJob(id: "job-4", state: .completed))
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: FakeLedger(),
            checkpointStore: HoloAgentCheckpointStore(directory: dir),
            jobStore: jobStore,
            resultStore: HoloAgentResultStore(directory: dir)
        )
        let reconciler = HoloAgentConsistencyReconciler(persistence: persistence)

        let report = try await reconciler.reconcile(now: baseTime.addingTimeInterval(3600))

        XCTAssertEqual(report.resultsConverged, 1, "应删除 1 条旧 result")
        let resultStore = HoloAgentResultStore(directory: dir)
        let remaining = try await resultStore.all()
        XCTAssertEqual(remaining.count, 1, "收敛后每 job 只剩 1 条 result")
        XCTAssertEqual(remaining.first?.id, "agent-result:job-4", "应保留 generatedAt 最新一条")
        // job 已 completed 且有 result → 不应被误判为缺失
        XCTAssertEqual(report.jobsFailedMissingResult, 0)
    }

    /// 健康数据：终态 + result 齐全、非终态 + evidence 完整 → 不做任何改动。
    func testReconcile_健康状态不产生修复() async throws {
        let fixture = makeFixture()
        try await fixture.jobStore.upsert(makeJob(id: "job-5", state: .running))
        try await fixture.checkpointStore.upsert(makeCheckpoint(id: "cp-5", jobID: "job-5", evidenceIDs: []))

        let report = try await fixture.reconciler.reconcile(now: baseTime.addingTimeInterval(3600))

        XCTAssertFalse(report.hasFixes, "健康状态不应产生修复：\(report)")
        let stored = try await fixture.jobStore.load().first { $0.id == "job-5" }
        XCTAssertEqual(stored?.state, .running)
    }
}
