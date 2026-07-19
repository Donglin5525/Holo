//
//  HoloAgentPersistenceStoreTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.3 Job/Checkpoint/Result Store 测试
//  §5.4/§5.5：load 改 throws；ResultStore 按 jobID 唯一 upsert。
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/"*.swift \
//    "Holo/Services/AI/Agent/Persistence/"*.swift \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    <本测试> -o /tmp/holo_agent_persistence_test && /tmp/holo_agent_persistence_test
//

import Foundation

@main
struct HoloAgentPersistenceStoreTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testJobStore_upsert后load能读到()
        try await testJobStore_updateState更新状态与时间()
        try await testCheckpointStore_按jobID查最新()
        try await testResultStore_upsert后按jobID查到()
        try await testResultStore_同job两次upsert只留一条()
        try await testJobStore_cleanup按retention清理过期()
        print("HoloAgentPersistenceStoreTests passed")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-stores-test-\(UUID().uuidString)")
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

    private static func makeResult(id: String, jobID: String, generatedAt: Date) -> HoloAgentResult {
        HoloAgentResult(
            id: id, jobID: jobID, title: "洞察", summary: "摘要",
            claims: [], evidenceIDs: [], memoryCandidateIDs: [],
            status: "completed",
            generatedAt: generatedAt, updatedAt: generatedAt
        )
    }

    // MARK: - JobStore

    private static func testJobStore_upsert后load能读到() async throws {
        let dir = makeTempDir()
        let store = HoloAgentJobStore(directory: dir)
        try await store.upsert(makeJob(id: "job-1", state: .queued, updatedAt: Date(timeIntervalSince1970: 1000)))
        let loaded = try await store.load()
        expect(loaded.count == 1, "upsert 后应读到 1 个 job，实际 \(loaded.count)")
        expect(loaded.first?.id == "job-1", "应读到 job-1")
    }

    private static func testJobStore_updateState更新状态与时间() async throws {
        let dir = makeTempDir()
        let store = HoloAgentJobStore(directory: dir)
        try await store.upsert(makeJob(id: "job-2", state: .queued, updatedAt: Date(timeIntervalSince1970: 1000)))
        let newTime = Date(timeIntervalSince1970: 5000)
        let found = try await store.updateState(jobID: "job-2", to: .running, now: newTime)
        expect(found == true, "应找到并更新 job-2")
        let target = try await store.load().first { $0.id == "job-2" }
        expect(target?.state == .running, "状态应更新为 running")
        expect(target?.updatedAt == newTime, "updatedAt 应更新为 \(newTime)")
    }

    // MARK: - CheckpointStore

    private static func testCheckpointStore_按jobID查最新() async throws {
        let dir = makeTempDir()
        let store = HoloAgentCheckpointStore(directory: dir)
        try await store.upsert(makeCheckpoint(id: "cp-1", jobID: "job-3", updatedAt: Date(timeIntervalSince1970: 1000)))
        try await store.upsert(makeCheckpoint(id: "cp-2", jobID: "job-3", updatedAt: Date(timeIntervalSince1970: 5000)))
        try await store.upsert(makeCheckpoint(id: "cp-x", jobID: "job-other", updatedAt: Date(timeIntervalSince1970: 9999)))
        let latest = try await store.latestForJob(jobID: "job-3")
        expect(latest?.id == "cp-2", "job-3 的最新 checkpoint 应是 cp-2，实际 \(latest?.id ?? "nil")")
    }

    // MARK: - ResultStore

    private static func testResultStore_upsert后按jobID查到() async throws {
        let dir = makeTempDir()
        let store = HoloAgentResultStore(directory: dir)
        try await store.upsert(makeResult(id: "res-1", jobID: "job-4", generatedAt: Date(timeIntervalSince1970: 1000)))
        let found = try await store.forJob(jobID: "job-4")
        expect(found?.id == "res-1", "应按 jobID 查到 res-1")
    }

    /// §5.4：同一 job 两次 upsert 只保留一条（替换而非累积，P0-6）。
    private static func testResultStore_同job两次upsert只留一条() async throws {
        let dir = makeTempDir()
        let store = HoloAgentResultStore(directory: dir)
        try await store.upsert(makeResult(id: "res-old", jobID: "job-5", generatedAt: Date(timeIntervalSince1970: 1000)))
        var newer = makeResult(id: "agent-result:job-5", jobID: "job-5", generatedAt: Date(timeIntervalSince1970: 2000))
        newer.summary = "新结论"
        try await store.upsert(newer)

        let all = try await store.all()
        expect(all.count == 1, "同 job 两次 upsert 应只剩 1 条，实际 \(all.count)")
        let found = try await store.forJob(jobID: "job-5")
        expect(found?.id == "agent-result:job-5", "应保留后写入的 canonical result，实际 \(found?.id ?? "nil")")
        expect(found?.summary == "新结论", "应保留后写入的内容")
    }

    // MARK: - Cleanup

    private static func testJobStore_cleanup按retention清理过期() async throws {
        let dir = makeTempDir()
        let store = HoloAgentJobStore(directory: dir)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400

        // completed 超 30 天 → 清理
        try await store.upsert(makeJob(id: "old-done", state: .completed, updatedAt: now.addingTimeInterval(-31 * day)))
        // completed 未超 30 天 → 保留
        try await store.upsert(makeJob(id: "fresh-done", state: .completed, updatedAt: now.addingTimeInterval(-10 * day)))
        // failed 超 7 天 → 清理
        try await store.upsert(makeJob(id: "old-fail", state: .failed, updatedAt: now.addingTimeInterval(-8 * day)))
        // running（非终态）→ 保留
        try await store.upsert(makeJob(id: "running", state: .running, updatedAt: now.addingTimeInterval(-100 * day)))

        let removed = try await store.cleanup(policy: HoloJobCleanupPolicy(), now: now)
        expect(removed.count == 2, "应清理 2 个（old-done, old-fail），实际 \(removed.count)")

        let remainingIDs = Set(try await store.load().map { $0.id })
        expect(remainingIDs == ["fresh-done", "running"], "应保留 fresh-done 和 running，实际 \(remainingIDs)")
    }
}
