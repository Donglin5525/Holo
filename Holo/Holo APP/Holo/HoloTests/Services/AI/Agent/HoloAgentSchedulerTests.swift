//
//  HoloAgentSchedulerTests.swift
//  HoloTests
//
//  HoloAI Agent V3.2 — Phase 1 Scheduler 测试
//  验证 N1 闭合：App 被杀重启后，Scheduler 真正拉起未完成 job 的 runLoop 到达终态，
//  而非现状「resume 标 running 即返回 → 下次回前台被 where state != .running 排除 → 永久晾死」。
//  XCTest 风格，纳入 HoloTests target，可用 test_sim 验证。
//

import XCTest
@testable import Holo

final class HoloAgentSchedulerTests: XCTestCase {

    // MARK: - Fakes（与 HoloLocalAgentRuntimeTests 对齐，XCTest 单元独立命名以避免冲突）

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

    private actor FakeLLM: HoloAgentLLMClientProtocol {
        private let responses: [String]
        private(set) var callCount = 0
        init(responses: [String]) { self.responses = responses }
        func next(messages: [HoloAgentMessage]) async throws -> String {
            let response = responses[min(callCount, responses.count - 1)]
            callCount += 1
            return response
        }
    }

    private actor FakeExecutor: HoloAgentToolExecuting {
        func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
            HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .success,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [],
                error: nil
            )
        }
        func promptDescription() async -> String { "" }
    }

    // MARK: - Helpers

    private struct LoopFixture {
        let runtime: HoloLocalAgentRuntime
        let jobStore: HoloAgentJobStore
        let checkpointStore: HoloAgentCheckpointStore
    }

    private func makeLoopFixture(dir: URL,
                                 llm: HoloAgentLLMClientProtocol,
                                 executor: HoloAgentToolExecuting) -> LoopFixture {
        let ledger = FakeLedger()
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let jobStore = HoloAgentJobStore(directory: dir)
        let resultStore = HoloAgentResultStore(directory: dir)
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: resultStore
        )
        let runtime = HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            llmClient: llm,
            toolExecutor: executor
        )
        return LoopFixture(runtime: runtime, jobStore: jobStore, checkpointStore: checkpointStore)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-scheduler-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isTerminal(_ state: HoloAgentJobState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }

    // MARK: - N1 回归

    /// N1：App 被杀重启后，未完成 job 必须由 Scheduler 真正拉起 runLoop 到达终态。
    /// 现状（RED）：resumeUnfinishedJobs 把 waitingForForeground 标成 running 即返回，
    /// 不重启推理；job 停在 running，断言终态失败。
    func testResumeAfterKillRestart_reachesTerminal() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#

        // 第一次运行：创建 job → 进后台暂停（waitingForForeground），模拟进程随后被系统杀掉。
        let run1 = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let job = try await run1.runtime.startAnalysisJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        try await run1.runtime.pauseForBackground(now: Date(timeIntervalSince1970: 2000))

        // 模拟 App 重启：新 runtime 实例（同磁盘目录）+ Scheduler 接管恢复。
        let run2 = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: run2.runtime)

        let resumed = try await scheduler.resumeAndContinue(
            systemTemplate: "你是 Agent",
            toolDescriptions: "tools",
            now: Date(timeIntervalSince1970: 3000)
        )
        XCTAssertEqual(resumed, 1, "应恢复 1 个未完成任务")

        let finalJob = await run2.jobStore.load().first { $0.id == job.id }
        guard let finalJob else {
            XCTFail("恢复后应能读到 job")
            return
        }
        XCTAssertTrue(isTerminal(finalJob.state),
                      "未完成 job 经 Scheduler 恢复后应到达终态，实际 \(finalJob.state.rawValue)")
    }

    /// §9.6 终态清理：超保留期的终态 job 及其 checkpoint 被删除；非终态 job 保留。
    func testCleanupTerminalJobs_删终态超期job并级联清理checkpoint() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(
            dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor()
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let policy = HoloJobCleanupPolicy(completedRetentionDays: 30, failedRetentionDays: 7)

        // 终态超期 job：startAnalysisJob 造 job+checkpoint，再改 completed + 40 天前（超 30 天保留期）
        let oldJob = try await fixture.runtime.startAnalysisJob(question: "old", now: now)
        var oldTerminal = oldJob
        oldTerminal.state = .completed
        oldTerminal.updatedAt = now.addingTimeInterval(-40 * 86_400)
        try await fixture.jobStore.upsert(oldTerminal)

        // 非终态 job（running，应保留）
        let activeJob = try await fixture.runtime.startAnalysisJob(question: "active", now: now)

        let removed = try await fixture.runtime.cleanupTerminalJobs(policy: policy, now: now)
        XCTAssertEqual(removed, [oldTerminal.id], "应只清理终态超期 job")

        let jobs = await fixture.jobStore.load()
        XCTAssertFalse(jobs.contains { $0.id == oldTerminal.id }, "终态超期 job 应被删除")
        XCTAssertTrue(jobs.contains { $0.id == activeJob.id }, "非终态 job 应保留")

        let oldCheckpoint = await fixture.checkpointStore.latestForJob(jobID: oldTerminal.id)
        XCTAssertNil(oldCheckpoint, "终态超期 job 的 checkpoint 应级联删除")
    }

    /// Phase 1 限量恢复：多 job 时只恢复有限个（按优先级排序），避免回前台批量恢复拖慢首屏。
    func testResumeAndContinue_限量恢复按优先级排序() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // 造 3 个 job（均 P0 userQuestion）→ 进后台 waitingForForeground → 改 trigger 制造优先级差异
        let j0 = try await fixture.runtime.startAnalysisJob(question: "P0", now: now)
        let j1 = try await fixture.runtime.startAnalysisJob(question: "P1", now: now)
        let j3 = try await fixture.runtime.startAnalysisJob(question: "P3", now: now)
        try await fixture.runtime.pauseForBackground(now: now)
        try await upsertTrigger(fixture.jobStore, id: j1.id, trigger: .memoryGalleryRefresh)
        try await upsertTrigger(fixture.jobStore, id: j3.id, trigger: .observerTier2)

        // 限量 2：应恢复 P0(userQuestion, rank=0) + P1(memoryGalleryRefresh, rank=1)，排除 P3(observerTier2, rank=2)
        let resumed = try await scheduler.resumeAndContinue(
            systemTemplate: "你是 Agent", toolDescriptions: "tools", now: now, maxResume: 2
        )
        XCTAssertEqual(resumed, 2, "应只恢复限量 2 个")

        let jobs = await fixture.jobStore.load()
        guard let f0 = jobs.first(where: { $0.id == j0.id }),
              let f1 = jobs.first(where: { $0.id == j1.id }),
              let f3 = jobs.first(where: { $0.id == j3.id }) else {
            XCTFail("jobs 应存在"); return
        }
        XCTAssertTrue(isTerminal(f0.state), "P0 应到达终态，实际 \(f0.state.rawValue)")
        XCTAssertTrue(isTerminal(f1.state), "P1 应到达终态，实际 \(f1.state.rawValue)")
        // P3 被限量排除，应保持 waitingForForeground
        XCTAssertFalse(isTerminal(f3.state), "P3 应被限量排除，实际 \(f3.state.rawValue)")
        XCTAssertEqual(f3.state, .waitingForForeground, "P3 应保持 waitingForForeground")
    }

    private func upsertTrigger(_ store: HoloAgentJobStore, id: String, trigger: HoloAgentTrigger) async throws {
        let jobs = await store.load()
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.trigger = trigger
        try await store.upsert(job)
    }

    /// Phase 2：Scheduler.start 创建 job 并跑完 runLoop，返回终态 job（Chat/Observer 入口经 Scheduler）。
    func testStart_创建job并跑完runLoop返回终态() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(
            dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor()
        )
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)

        let job = try await scheduler.start(
            question: "q", systemTemplate: "你是 Agent", toolDescriptions: "tools",
            now: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(job.state, .completed, "start 应跑完 runLoop 到达 completed")
        XCTAssertEqual(job.type, .deepAnalysis, "start 创建的应为 deepAnalysis job")
    }
}
