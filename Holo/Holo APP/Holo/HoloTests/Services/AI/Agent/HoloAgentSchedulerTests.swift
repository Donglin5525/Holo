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
import UIKit
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
        private let delayNanos: UInt64
        private let hangFirstCall: Bool
        private let errorsByCallIndex: [Int: Error]
        private var gateContinuation: CheckedContinuation<Void, Never>?
        private var gateOpen = false
        private(set) var callCount = 0
        /// 每次调用收到的 step record（§5.3 幂等验证用；无幂等路径为 nil 元素）
        private(set) var steps: [HoloAgentLLMRequestRecord?] = []

        /// - hangFirstCall: 首次调用挂起（模拟慢网络/晚返回），直到 `releaseGate()` 放行；
        ///   挂起不响应取消，用于验证 generation guard 拒绝旧代次写回。
        /// - errorsByCallIndex: 指定第 N 次调用抛错（如 URLError 模拟网络中断）。
        init(responses: [String], delayNanos: UInt64 = 0, hangFirstCall: Bool = false,
             errorsByCallIndex: [Int: Error] = [:]) {
            self.responses = responses
            self.delayNanos = delayNanos
            self.hangFirstCall = hangFirstCall
            self.errorsByCallIndex = errorsByCallIndex
        }

        func next(messages: [HoloAgentMessage]) async throws -> String {
            try await next(messages: messages, step: nil)
        }

        func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String {
            let index = callCount
            callCount += 1
            steps.append(step)
            if hangFirstCall && index == 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if gateOpen {
                        continuation.resume()
                    } else {
                        gateContinuation = continuation
                    }
                }
            }
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            if let error = errorsByCallIndex[index] { throw error }
            return responses[min(index, responses.count - 1)]
        }

        /// 放行挂起的首次调用。
        func releaseGate() {
            gateOpen = true
            gateContinuation?.resume()
            gateContinuation = nil
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

    @MainActor
    private final class FakeBackgroundTaskClient: HoloBackgroundTaskClient {
        /// id → expirationHandler（支持多租约并存，§6.3 每个活跃 job 一个 legacy 租约）
        private(set) var handlers: [Int: () -> Void] = [:]
        /// id → name（断言租约与 jobID 绑定用）
        private(set) var names: [Int: String] = [:]
        private(set) var endedIDs: [Int] = []
        private var nextID = 0

        /// 兼容旧断言：任一租约被释放
        var didEnd: Bool { !endedIDs.isEmpty }
        /// 兼容旧断言：首个租约的 expirationHandler
        var expirationHandler: (() -> Void)? { handlers.sorted { $0.key < $1.key }.first?.value }
        /// 当前未释放的租约数
        var activeLeaseCount: Int { handlers.count }

        func beginBackgroundTask(named name: String,
                                 expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
            nextID += 1
            handlers[nextID] = expirationHandler
            names[nextID] = name
            return UIBackgroundTaskIdentifier(rawValue: nextID)
        }

        func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
            endedIDs.append(identifier.rawValue)
            handlers[identifier.rawValue] = nil
            names[identifier.rawValue] = nil
        }

        /// 触发系统到期（默认触发首个未释放租约；可按 id 指定）
        func expire(id: Int? = nil) {
            if let id {
                handlers[id]?()
            } else {
                handlers.sorted { $0.key < $1.key }.first?.value()
            }
        }
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

    private func waitUntil(_ predicate: @escaping () async -> Bool,
                           timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await predicate()
    }

    private func makeJob(
        state: HoloAgentJobState,
        step: HoloAgentStep,
        errorSummary: String? = nil
    ) -> HoloAgentJob {
        HoloAgentJob(
            id: UUID().uuidString,
            type: .deepAnalysis,
            userQuestion: "最近状态怎么样",
            trigger: .userQuestion,
            state: state,
            currentStep: step,
            createdAt: Date(),
            updatedAt: Date(),
            lastForegroundRunAt: nil,
            timeRange: nil,
            budget: HoloAgentBudget.normalDeep(),
            checkpointID: nil,
            resultID: nil,
            errorSummary: errorSummary,
            deviceID: nil
        )
    }

    func testChatStatusPresenter_按Job真实状态生成进度展示() {
        let running = HoloAgentChatStatusPresenter.status(
            for: makeJob(state: .waitingForLLM, step: .executeTools)
        )
        XCTAssertTrue(running.keepsMessageStreaming)
        XCTAssertTrue(running.showsActivityIndicator)
        XCTAssertEqual(running.title, "Holo 正在深度分析中…")

        let paused = HoloAgentChatStatusPresenter.status(
            for: makeJob(state: .waitingForForeground, step: .executeTools)
        )
        XCTAssertTrue(paused.keepsMessageStreaming)
        XCTAssertFalse(paused.showsActivityIndicator)
        XCTAssertEqual(paused.title, "已暂停，回到 App 后继续")

        let failed = HoloAgentChatStatusPresenter.status(
            for: makeJob(state: .failed, step: .executeTools, errorSummary: "网络中断")
        )
        XCTAssertFalse(failed.keepsMessageStreaming)
        XCTAssertFalse(failed.showsActivityIndicator)
        XCTAssertEqual(failed.title, "深度分析已中断")
        XCTAssertTrue(failed.detail.contains("网络中断"))
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
        // 注：恢复时间须在 absoluteDeadline（createdAt+1800s）内，否则按 §5.2 过期置失败。
        let run2 = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: run2.runtime)

        let resumed = try await scheduler.resumeAndContinue(
            systemTemplate: "你是 Agent",
            toolDescriptions: "tools",
            now: Date(timeIntervalSince1970: 2500)
        )
        XCTAssertEqual(resumed, 1, "应恢复 1 个未完成任务")

        let finalJob = try await run2.jobStore.load().first { $0.id == job.id }
        guard let finalJob else {
            XCTFail("恢复后应能读到 job")
            return
        }
        XCTAssertTrue(isTerminal(finalJob.state),
                      "未完成 job 经 Scheduler 恢复后应到达终态，实际 \(finalJob.state.rawValue)")
        let cp = try await run2.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertEqual(cp?.schemaVersion, 1, "新 checkpoint 应设 schemaVersion=1")
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

        let jobs = try await fixture.jobStore.load()
        XCTAssertFalse(jobs.contains { $0.id == oldTerminal.id }, "终态超期 job 应被删除")
        XCTAssertTrue(jobs.contains { $0.id == activeJob.id }, "非终态 job 应保留")

        let oldCheckpoint = try await fixture.checkpointStore.latestForJob(jobID: oldTerminal.id)
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

        let jobs = try await fixture.jobStore.load()
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
        let jobs = try await store.load()
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.trigger = trigger
        try await store.upsert(job)
    }

    private func upsertUserQuestion(_ store: HoloAgentJobStore, id: String, question: String) async throws {
        let jobs = try await store.load()
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.userQuestion = question
        try await store.upsert(job)
    }

    /// Phase 3：inputSnapshotHash 匹配则恢复，不匹配则跳过（用户改了输入，需重新规划）。
    func testResumeAndContinue_hash匹配恢复不匹配跳过() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date(timeIntervalSince1970: 1_000_000)

        // jobA: 原输入，hash 匹配 → 应恢复
        let jobA = try await fixture.runtime.startAnalysisJob(question: "original", now: now)
        // jobB: 创建后改 userQuestion → hash 不匹配 checkpoint → 应跳过
        let jobB = try await fixture.runtime.startAnalysisJob(question: "original", now: now)
        try await fixture.runtime.pauseForBackground(now: now)
        try await upsertUserQuestion(fixture.jobStore, id: jobB.id, question: "changed")

        let resumed = try await scheduler.resumeAndContinue(
            systemTemplate: "你是 Agent", toolDescriptions: "tools", now: now, maxResume: 5
        )
        XCTAssertEqual(resumed, 1, "只有 hash 匹配的 jobA 应被恢复")

        let jobs = try await fixture.jobStore.load()
        guard let fA = jobs.first(where: { $0.id == jobA.id }),
              let fB = jobs.first(where: { $0.id == jobB.id }) else {
            XCTFail("jobs 应存在"); return
        }
        XCTAssertTrue(isTerminal(fA.state), "jobA hash 匹配，应到达终态，实际 \(fA.state.rawValue)")
        XCTAssertFalse(isTerminal(fB.state), "jobB hash 不匹配，应保持 waitingForForeground")
        XCTAssertNotNil(fB.errorSummary, "hash 不匹配必须把跳过原因落盘（不得静默跳过）")
    }

    /// P0-1 回归：checkpoint 上是旧 Swift `Hasher` 值（非 64 hex）时不得拒绝恢复，
    /// 且恢复前重建为稳定 SHA-256 写回 checkpoint（§十 Phase 1 任务 2）。
    func testResumeAndContinue_legacyHasher值不拒绝恢复并重建稳定hash() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let job = try await fixture.runtime.startAnalysisJob(question: "legacy", now: now)
        try await fixture.runtime.pauseForBackground(now: now)

        // 把 checkpoint 的 hash 改写成旧 Hasher 十进制值（模拟 Phase 1 之前的数据）
        guard var checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id) else {
            XCTFail("checkpoint 应存在"); return
        }
        checkpoint.inputSnapshotHash = "-8523015869675982626"
        try await fixture.checkpointStore.upsert(checkpoint)

        let resumed = try await scheduler.resumeAndContinue(
            systemTemplate: "你是 Agent", toolDescriptions: "tools", now: now, maxResume: 5
        )
        XCTAssertEqual(resumed, 1, "legacy Hasher 值不得用于拒绝恢复")

        let migrated = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertEqual(migrated?.inputSnapshotHash?.count, 64, "恢复后应重建为 64 位稳定 hash")
        XCTAssertEqual(migrated?.inputSnapshotHash,
                       HoloAgentInputSnapshotHasher.hash(for: job),
                       "重建值必须与当前稳定快照一致")
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
            now: Date()
        )
        XCTAssertEqual(job.state, .completed, "start 应跑完 runLoop 到达 completed")
        XCTAssertEqual(job.type, .deepAnalysis, "start 创建的应为 deepAnalysis job")
    }

    /// Chat 恢复桥：用户发起的 Agent job 必须带 sourceMessageID，回前台恢复完成后才能回填原消息。
    func testStart_保存sourceMessageID供Chat恢复回填() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(
            dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor()
        )
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let messageID = UUID()

        let job = try await scheduler.start(
            question: "q",
            systemTemplate: "你是 Agent",
            toolDescriptions: "tools",
            sourceMessageID: messageID,
            now: Date()
        )

        XCTAssertEqual(job.sourceMessageID, messageID, "Agent job 应记录触发它的 Chat 消息 ID")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.sourceMessageID, messageID, "sourceMessageID 应随 job 落盘，供恢复回填")
    }

    /// 后台续跑：进入后台时不应立刻 pause，系统后台时间耗尽后才落盘 waitingForForeground。
    @MainActor
    func testBackgroundContinuation_进入后台保留运行到期后才暂停() async throws {
        let dir = makeTempDir()
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: []), executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let manager = HoloBackgroundContinuationManager(
            runtime: fixture.runtime,
            backgroundTaskClient: client
        )
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: Date())

        manager.appDidEnterBackground()
        // §6.3：场景租约异步申请，先等租约登记（本例无活跃执行 → scene-sweep 兜底租约）
        let leaseAttached = await waitUntil { client.activeLeaseCount >= 1 }
        XCTAssertTrue(leaseAttached, "进入后台应申请 legacy 租约")

        let afterBackground = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(afterBackground?.state, .running, "刚切后台应保留 running，让 iOS 后台任务继续推进")

        client.expire()
        let paused = await waitUntil {
            let stored = try? await fixture.jobStore.load().first { $0.id == job.id }
            return stored?.state == .waitingForForeground
        }
        XCTAssertTrue(paused, "后台时间到期后应标记 waitingForForeground，等待前台恢复")
        XCTAssertTrue(client.didEnd, "后台任务到期处理后应释放 UIBackgroundTask")
    }

    /// 快速回桌面再回来：如果后台时间还没到期，原 runLoop 仍可能在跑，前台恢复不能重复拉起第二条 runLoop。
    @MainActor
    func testBackgroundContinuation_未到期快速回前台不重复恢复RunningJob() async throws {
        let dir = makeTempDir()
        let llm = FakeLLM(responses: [
            #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        ])
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let manager = HoloBackgroundContinuationManager(
            runtime: fixture.runtime,
            backgroundTaskClient: client
        )
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: Date())

        manager.appDidEnterBackground()
        manager.appWillEnterForeground()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.state, .running, "后台时间未到期时，回前台只同步状态，不应重复 resume running job")
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 0, "快速切回不应额外触发 LLM 调用")
    }

    /// 后台时间到期：job 已明确暂停，回前台需要重启 runLoop 并推进到终态。
    @MainActor
    func testBackgroundContinuation_到期后回前台恢复暂停Job() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let manager = HoloBackgroundContinuationManager(
            runtime: fixture.runtime,
            backgroundTaskClient: client
        )
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: Date())

        manager.appDidEnterBackground()
        // §6.3：等场景租约异步登记后再触发系统到期
        let leaseAttached = await waitUntil { client.activeLeaseCount >= 1 }
        XCTAssertTrue(leaseAttached, "进入后台应申请 legacy 租约")
        client.expire()
        let paused = await waitUntil {
            let stored = try? await fixture.jobStore.load().first { $0.id == job.id }
            return stored?.state == .waitingForForeground
        }
        XCTAssertTrue(paused)

        manager.appWillEnterForeground()
        let completed = await waitUntil {
            let stored = try? await fixture.jobStore.load().first { $0.id == job.id }
            return stored?.state == .completed
        }
        XCTAssertTrue(completed, "后台时间到期暂停后，回前台应恢复 runLoop 并完成 job")
    }

    // MARK: - Phase 2 唯一执行权（§6.1，P0-2）

    /// 同一 job 并发 runOrAttach 只执行一次：第二个调用 attach 到同一 Task，
    /// 不产生第二次 LLM 调用，只 acquire 一次 generation（Phase 0 任务 2 / Phase 2 验收门）。
    func testRunOrAttach_同job并发attach只执行一次() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        // 100ms 慢响应，保证两次调用在执行窗口内重叠
        let llm = FakeLLM(responses: [finalClaims], delayNanos: 100_000_000)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()  // runLoop wall-time 预算按真实时钟判断，不能用历史假时间
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let first = scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        async let second = scheduler.runOrAttach(
            jobID: job.id, reason: .appLaunch, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let (job1, job2) = try await (first, second)

        XCTAssertEqual(job1.id, job2.id)
        XCTAssertEqual(job1.state, .completed)
        XCTAssertEqual(job2.state, .completed)
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 1, "attach 不得产生第二次 LLM 调用，实际 \(callCount)")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.executionGeneration, 1, "并发 attach 只应 acquire 一次 generation")
    }

    /// 旧 generation 的 LLM 晚返回不得写回（Phase 0 任务 3 / §12.3）：
    /// 新代次接管后，旧 runLoop 抛 staleExecution，不写 checkpoint/result。
    func testRunLoop_旧generation晚返回不得写回() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()  // runLoop wall-time 预算按真实时钟判断，不能用历史假时间
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        // 第一次执行：acquire gen1，LLM 挂起（模拟慢网络）
        async let first = scheduler.runOrAttach(
            jobID: job.id, reason: .appLaunch, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted, "LLM 应已被调用并挂起")

        // 模拟新执行接管：直接 acquire gen2（不取消旧 Task，正如跨进程/异常路径的孤儿 loop）
        _ = try await fixture.jobStore.acquireExecutionGeneration(jobID: job.id, now: now)

        // 放行旧 LLM：gen1 晚返回 → staleExecution，不得写回
        await llm.releaseGate()
        do {
            _ = try await first
            XCTFail("旧 generation 晚返回应抛 staleExecution")
        } catch let error as HoloAgentRuntimeError {
            guard case .staleExecution = error else {
                return XCTFail("应抛 staleExecution，实际 \(error)")
            }
        }

        // 旧代次不得写回：无 result，checkpoint 仍是初始 plan，job 不被完成
        let results = try await HoloAgentResultStore(directory: dir).all()
        XCTAssertTrue(results.isEmpty, "旧 generation 不得写入 result，实际 \(results.count) 条")
        let checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertEqual(checkpoint?.step, .plan, "旧 generation 不得推进 checkpoint")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertNotEqual(stored?.state, .completed, "旧 generation 不得把 job 写成 completed")
    }

    /// 快速切前后台（pause → runOrAttach）：旧执行取消让位，新代次接管到终态，
    /// 全程只有一个有效执行、一个 result（§12.3 快速 background → active）。
    func testPause_到期暂停后新代次接管且只有一个result() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()  // runLoop wall-time 预算按真实时钟判断，不能用历史假时间
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        // 第一次执行挂起在 LLM 调用上（App 切后台）
        async let first = scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)

        // 后台时间到期：取消旧执行 + 标记 waitingForForeground + 注册表让位
        await scheduler.pause(jobID: job.id, reason: .backgroundTimeExpired, now: now)
        let pausedJob = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(pausedJob?.state, .waitingForForeground)

        // 回前台恢复：新代次接管并完成（第二次 LLM 调用不挂起）
        let second = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(second.state, .completed)

        // 放行旧 LLM：旧执行已取消，不得写回任何东西
        await llm.releaseGate()
        do {
            _ = try await first
            XCTFail("已取消的旧执行不应正常返回")
        } catch {
            // CancellationError（guard 先命中取消）为预期
        }

        let results = try await HoloAgentResultStore(directory: dir).all()
        XCTAssertEqual(results.count, 1, "同一 job 全程只能有一个 result，实际 \(results.count)")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.executionGeneration, 2, "暂停后接管应 acquire 新 generation")
    }

    /// cancel 后：job 落 cancelled 终态、注册表清理、再次 runOrAttach 直接返回终态不重启执行。
    func testCancel_取消后返回cancelled且注册表清理() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()  // runLoop wall-time 预算按真实时钟判断，不能用历史假时间
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let first = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)

        await scheduler.cancel(jobID: job.id, source: .user, now: now)
        await llm.releaseGate()
        do {
            _ = try await first
            XCTFail("已取消的执行不应正常返回")
        } catch {
            // CancellationError 为预期（guard 先命中取消）
        }

        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.state, .cancelled, "取消后应落 cancelled 终态")

        // 注册表已清理：再次 runOrAttach 返回 cancelled 现状，不启动新执行
        let again = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(again.state, .cancelled)
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 1, "取消后不得再触发 LLM 调用，实际 \(callCount)")

        let results = try await HoloAgentResultStore(directory: dir).all()
        XCTAssertTrue(results.isEmpty, "取消后不得写入 result")
    }

    /// generation CAS：两个并发 acquire 得到递增值，validate 只认最新（§6.1）。
    func testGenerationCAS_并发acquire递增值() async throws {
        let dir = makeTempDir()
        let jobStore = HoloAgentJobStore(directory: dir)
        let job = makeJob(state: .running, step: .plan)
        try await jobStore.upsert(job)

        async let acquire1 = jobStore.acquireExecutionGeneration(jobID: job.id)
        async let acquire2 = jobStore.acquireExecutionGeneration(jobID: job.id)
        let (generation1, generation2) = try await (acquire1, acquire2)

        XCTAssertEqual(Set([generation1, generation2]), [1, 2], "并发 acquire 应得到递增值，不得重复")
        let stored = try await jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.executionGeneration, 2)
        let validLatest = try await jobStore.validateExecutionGeneration(jobID: job.id, generation: 2)
        XCTAssertTrue(validLatest)
        let validOld = try await jobStore.validateExecutionGeneration(jobID: job.id, generation: 1)
        XCTAssertFalse(validOld, "旧 generation 应校验失败")
    }

    /// P0 并发上限：P0 活跃时低优先级（Observer 等）任务不启动，跳过并落盘原因（§2.2/§6.1）。
    func testRunOrAttach_P0活跃时低优任务跳过并落盘原因() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()  // runLoop wall-time 预算按真实时钟判断，不能用历史假时间

        // P0 用户任务挂起执行中
        let p0Job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)
        async let p0Run = scheduler.runOrAttach(
            jobID: p0Job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)

        // 低优任务（observerTier2）：P0 活跃时不启动
        let observerJob = try await fixture.runtime.startAnalysisJob(question: "observer", now: now)
        try await upsertTrigger(fixture.jobStore, id: observerJob.id, trigger: .observerTier2)
        let skipped = try await scheduler.runOrAttach(
            jobID: observerJob.id, reason: .appLaunch, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(skipped.state, .running, "低优任务应未被推进（保持原状态）")
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 1, "低优任务不得触发 LLM 调用，实际 \(callCount)")
        let stored = try await fixture.jobStore.load().first { $0.id == observerJob.id }
        XCTAssertNotNil(stored?.errorSummary, "跳过必须落盘可解释原因（不静默）")

        // 收尾：取消 P0 并放行
        await scheduler.cancel(jobID: p0Job.id, source: .user, now: now)
        await llm.releaseGate()
        do {
            _ = try await p0Run
            XCTFail("已取消的 P0 执行不应正常返回")
        } catch {
            // CancellationError 为预期
        }
    }

    // MARK: - Phase 3 预算与等待条件（§5.2/§7，P0-3/P0-4）

    /// 锁屏可切换的严格健康数据源（§7.1 测试用）。
    private final class LockableHealthDataSource: HoloHealthDataSource, @unchecked Sendable {
        var locked = true
        func dailyRecords(for metric: HoloHealthMetricKind, timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] { [] }
        func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord] { [] }
        func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloSleepRecord] { [] }
        func sleepRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloSleepRecord]> {
            if locked { return .waitingForUnlock }
            return .value([
                HoloSleepRecord(
                    date: Date(), totalHours: 7, coreHours: 4, deepHours: 1.5,
                    remHours: 1.5, awakeHours: nil, inBedHours: 7.5,
                    bedtime: nil, wakeTime: nil, interruptionCount: nil
                )
            ])
        }
    }

    /// Phase 0 任务 4 / §5.2：暂停/等待不消耗 active runtime（旧 wall-clock 实现此刻必误判耗尽）。
    func testActiveRuntime_暂停等待不消耗运行预算() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var job = makeJob(state: .running, step: .executeTools)
        job.budget.maxWallTimeSeconds = 120

        // 执行 10 秒 → 进入等待（结算段）
        job.beginActiveSegment(at: t0)
        job.endActiveSegment(at: t0.addingTimeInterval(10))
        XCTAssertEqual(job.consumedActiveRuntime ?? -1, 10, accuracy: 0.001)

        // 等待 3 分钟（锁屏/暂停）：不得计入；恢复执行 5 秒
        job.beginActiveSegment(at: t0.addingTimeInterval(190))
        let afterResume5s = t0.addingTimeInterval(195)
        XCTAssertEqual(job.activeRuntimeSeconds(at: afterResume5s), 15, accuracy: 0.001,
                       "等待的 180 秒不得计入 active runtime")
        XCTAssertFalse(job.isActiveRuntimeExhausted(at: afterResume5s),
                       "旧实现（wall-clock 195s > 120s）会误判耗尽，active runtime 语义下未耗尽")

        // 继续执行到 active runtime 达 120 秒 → 耗尽
        let exhaustedAt = t0.addingTimeInterval(190 + 110 + 1)
        XCTAssertTrue(job.isActiveRuntimeExhausted(at: exhaustedAt))

        // 已有开放段时重复开段不得重置（崩溃残留按保守语义继续累计）
        let segmentStart = job.activeSegmentStartedAt
        job.beginActiveSegment(at: t0.addingTimeInterval(999))
        XCTAssertEqual(job.activeSegmentStartedAt, segmentStart)
    }

    /// Phase 0 任务 5 / §7.2：锁屏查询健康 → waitingForCondition+deviceUnlock，
    /// 不产生伪零证据，checkpoint 已保存；解锁后 Scheduler 恢复到终态。
    func testRunLoop_健康锁屏进入等待解锁且恢复后完成() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"查询睡眠","toolRequests":[{"id":"t-sleep","tool":"health","query":"sleep_summary","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [needTools, finalClaims])
        let healthSource = LockableHealthDataSource()
        let executor = HoloToolExecutor(registry: HoloToolRegistry(tools: [HoloHealthTool(dataSource: healthSource)]))
        let ledger = FakeLedger()
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let jobStore = HoloAgentJobStore(directory: dir)
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: HoloAgentResultStore(directory: dir)
        )
        let runtime = HoloLocalAgentRuntime(
            persistence: persistence, jobStore: jobStore, checkpointStore: checkpointStore,
            llmClient: llm, toolExecutor: executor
        )
        let scheduler = HoloAgentScheduler(runtime: runtime)
        let now = Date()
        let job = try await runtime.startAnalysisJob(question: "最近睡眠怎么样", now: now)

        // 锁屏：工具返回 DEVICE_LOCKED → 等待解锁，不落失败、不产生伪零证据
        let first = try await scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(first.state, .waitingForCondition)
        XCTAssertEqual(first.waitReason, .deviceUnlock)
        XCTAssertNil(first.errorSummary, "锁屏等待不是失败，不得写错误信息")
        let checkpoint = try await checkpointStore.latestForJob(jobID: job.id)
        XCTAssertNotNil(checkpoint, "等待前必须已保存 checkpoint（可恢复断点）")
        XCTAssertTrue(checkpoint?.completedToolResults.isEmpty == true,
                      "锁屏不得写入工具结果（伪零证据）")
        XCTAssertTrue(checkpoint?.evidenceRecordIDs.isEmpty == true, "锁屏不得产生 evidence")
        let evidence = await ledger.load()
        XCTAssertTrue(evidence.isEmpty, "锁屏不得写入 evidence ledger")

        // 解锁：Scheduler 恢复执行到终态（已完成工具不重复查询，未完成的重新查）
        healthSource.locked = false
        let second = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(second.state, .completed)
        XCTAssertNil(second.waitReason, "恢复执行后等待原因应清空")
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 2, "恢复后从断点继续，共两轮 LLM 调用，实际 \(callCount)")
    }

    /// §7.2：可恢复网络错误 → waitingForCondition+network 落盘（不晾在 running）；恢复后完成。
    func testRunLoop_网络错误进入等待网络且恢复后完成() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(
            responses: [finalClaims],
            errorsByCallIndex: [0: URLError(.notConnectedToInternet)]
        )
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        let first = try await scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(first.state, .waitingForCondition)
        XCTAssertEqual(first.waitReason, .network)
        XCTAssertNil(first.errorSummary, "可恢复网络等待不是失败")
        let checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertNotNil(checkpoint, "等待前必须已保存 checkpoint")

        // 网络恢复：第二次 runOrAttach 走到终态
        let second = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(second.state, .completed)
        XCTAssertNil(second.waitReason)
    }

    /// §5.2：新 P0 抢占时旧任务落 superseded 终态（Phase 2 是 cancel 语义，本批改为新终态）。
    func testP0抢占_旧任务落superseded终态() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()

        let jobA = try await fixture.runtime.startAnalysisJob(question: "A", now: now)
        async let runA = scheduler.runOrAttach(
            jobID: jobA.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)

        // 新 P0 到达：P0 门控抢占旧任务
        let jobB = try await fixture.runtime.startAnalysisJob(question: "B", now: now)
        async let runB = scheduler.runOrAttach(
            jobID: jobB.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        await llm.releaseGate()
        let completedB = try await runB
        XCTAssertEqual(completedB.state, .completed)

        let storedA = try await fixture.jobStore.load().first { $0.id == jobA.id }
        XCTAssertEqual(storedA?.state, .superseded, "被取代的旧任务应为 superseded 终态")
        XCTAssertEqual(storedA?.waitReason, .inputChanged)

        do {
            _ = try await runA
            XCTFail("被取代的执行不应正常返回")
        } catch {
            // CancellationError 为预期
        }
    }

    /// §5.2：超过 absoluteDeadline 的等待任务不再恢复，恢复评估时置失败（防止无限等待）。
    func testAbsoluteDeadline_过期等待任务恢复时置失败() async throws {
        let dir = makeTempDir()
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: []), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)

        var job = makeJob(state: .waitingForCondition, step: .executeTools)
        job.waitReason = .deviceUnlock
        job.absoluteDeadline = Date().addingTimeInterval(-60)
        try await fixture.jobStore.upsert(job)

        let resumed = try await scheduler.resumeEligibleJobs(
            trigger: .appLaunch, systemTemplate: "s", toolDescriptions: "t"
        )
        XCTAssertEqual(resumed, 0, "过期任务不得恢复")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.state, .failed, "过期等待任务应置失败")
        XCTAssertNotNil(stored?.errorSummary)
    }

    /// §5.2/§7.2：新状态在 Chat 状态文案的映射（waitingForCondition 按 waitReason 区分，superseded 终态）。
    func testChatStatusPresenter_等待条件与superseded文案() {
        var lockJob = makeJob(state: .waitingForCondition, step: .executeTools)
        lockJob.waitReason = .deviceUnlock
        let lockStatus = HoloAgentChatStatusPresenter.status(for: lockJob)
        XCTAssertEqual(lockStatus.title, "等待设备解锁")
        XCTAssertTrue(lockStatus.detail.contains("解锁后继续读取健康数据"))
        XCTAssertTrue(lockStatus.keepsMessageStreaming, "等待解锁不是失败，消息保持流式")
        XCTAssertFalse(lockStatus.showsActivityIndicator)

        var networkJob = makeJob(state: .waitingForCondition, step: .executeTools)
        networkJob.waitReason = .network
        let networkStatus = HoloAgentChatStatusPresenter.status(for: networkJob)
        XCTAssertEqual(networkStatus.title, "等待网络恢复")
        XCTAssertTrue(networkStatus.keepsMessageStreaming)

        let supersededStatus = HoloAgentChatStatusPresenter.status(
            for: makeJob(state: .superseded, step: .executeTools)
        )
        XCTAssertEqual(supersededStatus.title, "已被新的分析取代")
        XCTAssertFalse(supersededStatus.keepsMessageStreaming)
        XCTAssertFalse(supersededStatus.showsActivityIndicator)
    }

    // MARK: - Phase 4 step 幂等（§5.3/§8.1，P0-7）

    /// step 幂等灰度开关的 UserDefaults key（与 HoloAICapability.Keys 一致）。
    private static let stepIdempotencyFlagKey = "holo_agent_stepIdempotencyEnabled"

    /// 开启 step 幂等开关，测试结束自动还原（防止跨测试污染）。
    /// 注：读路径经 HoloMemorySettings.shared（live 单例），UserDefaults 只在 init 时读一次。
    private func enableStepIdempotency() {
        let settings = HoloMemorySettings.shared
        let original = settings.agentStepIdempotencyEnabled
        settings.agentStepIdempotencyEnabled = true
        addTeardownBlock {
            settings.agentStepIdempotencyEnabled = original
        }
    }

    /// §5.3：请求前持久化 prepared record（fake 收到即 prepared），完成后 checkpoint 为 applied。
    func testStepIdempotency_请求前持久化record且完成后标记applied() async throws {
        enableStepIdempotency()
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims])
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        let final = try await scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(final.state, .completed)

        let steps = await llm.steps
        XCTAssertEqual(steps.count, 1)
        let sentRecord = try XCTUnwrap(steps[0] ?? nil, "开启后必须携带 step record")
        XCTAssertEqual(sentRecord.runID, job.id)
        XCTAssertEqual(sentRecord.stepID, "llm-1-1", "stepID 应为 llm-<轮次>-<revision>")
        XCTAssertEqual(sentRecord.status, .prepared, "请求发起时 record 应为 prepared（请求前已持久化）")
        XCTAssertTrue(HoloAgentInputSnapshotHasher.isStableHash(sentRecord.requestHash),
                      "requestHash 应为 64 位稳定 hex")

        let checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertEqual(checkpoint?.pendingLLMRequest?.stepID, "llm-1-1")
        XCTAssertEqual(checkpoint?.pendingLLMRequest?.status, .applied, "输出应用后应标记 applied")
        XCTAssertNotNil(checkpoint?.pendingLLMRequest?.responseHash, "completed 应落 responseHash")
        XCTAssertEqual(checkpoint?.revision, 1)
        XCTAssertEqual(checkpoint?.executionGeneration, 1, "checkpoint 应记录写入的 generation")
    }

    /// §5.3/§8.2：「请求后崩溃」恢复复用同一 stepID+requestHash 重新请求（后端幂等返回同一响应）。
    func testStepIdempotency_请求后崩溃恢复复用同一step() async throws {
        enableStepIdempotency()
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        // 第一次执行：prepared 落盘后 LLM 挂起（模拟请求在途）
        async let first = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let preparedSaved = await waitUntil {
            let checkpoint = try? await fixture.checkpointStore.latestForJob(jobID: job.id)
            return checkpoint?.pendingLLMRequest?.status == .prepared
        }
        XCTAssertTrue(preparedSaved, "请求在途时 checkpoint 必须已含 prepared record")

        // 模拟请求后崩溃：取消在途执行并让位注册表（旧写回会被 guard 拒绝）
        await scheduler.pause(jobID: job.id, reason: .backgroundTimeExpired, now: now)
        await llm.releaseGate()

        // 恢复：复用同一 stepID+requestHash 重新请求
        let second = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(second.state, .completed)

        let steps = await llm.steps
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0]?.stepID, steps[1]?.stepID,
                       "崩溃恢复必须复用同一 stepID（后端幂等返回同一响应）")
        XCTAssertEqual(steps[0]?.requestHash, steps[1]?.requestHash,
                       "同一 step 的 requestHash 必须一致")

        do {
            _ = try await first
            XCTFail("被取代的旧执行不应正常返回")
        } catch {
            // CancellationError / staleExecution 均为预期
        }
    }

    /// §8.1 兼容：开关关闭走旧路径——不带 step 字段、不持久化 request record（旧后端行为不变）。
    func testStepIdempotency_开关关闭不带step字段() async throws {
        let settings = HoloMemorySettings.shared
        let original = settings.agentStepIdempotencyEnabled
        settings.agentStepIdempotencyEnabled = false
        defer { settings.agentStepIdempotencyEnabled = original }
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims])
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        let final = try await scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(final.state, .completed)

        let steps = await llm.steps
        XCTAssertEqual(steps.count, 1)
        XCTAssertNil(steps[0] ?? nil, "开关关闭不得携带 step 字段")
        let checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertNil(checkpoint?.pendingLLMRequest, "开关关闭不得持久化 request record")
        XCTAssertNil(checkpoint?.revision, "开关关闭不写 revision")
    }

    /// §8.1：DTO 三字段必须同时编码或同时缺失（后端部分缺失 400 / 全缺兼容）。
    func testStepIdempotency_DTO三字段同时编码或缺失() throws {
        let messages = [ChatMessageDTO(role: "user", content: "hi")]
        let withStep = HoloBackendChatCompletionRequest(
            purpose: "agent_loop", messages: messages, stream: false, responseFormat: nil,
            runId: "run-1", stepId: "llm-1-1", requestHash: "abc123"
        )
        let withJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(withStep)) as? [String: Any]
        )
        XCTAssertEqual(withJSON["runId"] as? String, "run-1")
        XCTAssertEqual(withJSON["stepId"] as? String, "llm-1-1")
        XCTAssertEqual(withJSON["requestHash"] as? String, "abc123")

        let withoutStep = HoloBackendChatCompletionRequest(
            purpose: "agent_loop", messages: messages, stream: false, responseFormat: nil
        )
        let withoutJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutStep)) as? [String: Any]
        )
        XCTAssertNil(withoutJSON["runId"], "无 step 时不得编码 runId（全缺才走后端兼容路径）")
        XCTAssertNil(withoutJSON["stepId"])
        XCTAssertNil(withoutJSON["requestHash"])
    }

    // MARK: - Phase 5 执行租约（§6.3/§6.4/§9.6）

    /// §6.3：切后台为活跃 job 申请绑定 jobID 的 legacy 租约；job 完成立即释放（不等场景/expiration）。
    @MainActor
    func testLease_切后台为活跃job绑定legacy租约_完成立即释放() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], delayNanos: 150_000_000)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, backgroundTaskClient: client)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let run = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        // 先等执行登记并进入 LLM 调用（否则 sceneDidEnterBackground 只看到空注册表，拿到 scene-sweep 租约）
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)
        await scheduler.sceneDidEnterBackground()
        XCTAssertEqual(client.activeLeaseCount, 1, "活跃 job 应有一个 legacy 租约")
        let leaseName = client.names.values.first
        XCTAssertTrue(leaseName?.contains(String(job.id.prefix(8))) == true,
                      "租约应绑定具体 jobID，实际 \(leaseName ?? "nil")")

        let finalJob = try await run
        XCTAssertEqual(finalJob.state, .completed)
        let released = await waitUntil { !client.endedIDs.isEmpty }
        XCTAssertTrue(released, "job 完成应立即 endBackgroundTask 释放租约")
        XCTAssertEqual(client.activeLeaseCount, 0, "完成后不得滞留后台时间")
    }

    /// §6.4：lease expiration 只做取消信号 + 状态标记 + 尽快释放，不承担 checkpoint 保存。
    @MainActor
    func testLease_expiration取消对应Task并落等待前台无额外checkpoint() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], hangFirstCall: true)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, backgroundTaskClient: client)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let run = scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)
        await scheduler.sceneDidEnterBackground()
        XCTAssertEqual(client.activeLeaseCount, 1)

        client.expire()
        let paused = await waitUntil {
            let stored = try? await fixture.jobStore.load().first { $0.id == job.id }
            return stored?.state == .waitingForForeground
        }
        XCTAssertTrue(paused, "expiration 后 job 应落 waitingForForeground")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.waitReason, .backgroundTimeExpired)
        XCTAssertTrue(client.didEnd, "expiration 后租约应尽快释放")

        // 旧执行已取消：放行挂起的 LLM，晚返回不得写回
        await llm.releaseGate()
        do {
            _ = try await run
            XCTFail("到期后旧执行不应正常返回")
        } catch {
            // CancellationError / staleExecution 均为预期
        }
        let checkpoint = try await fixture.checkpointStore.latestForJob(jobID: job.id)
        XCTAssertEqual(checkpoint?.step, .plan, "expiration 不得承担 checkpoint 推进/保存")
    }

    /// §9.6：快速 background → active → 同 job 只 attach 不重启；回前台归还后台时间。
    @MainActor
    func testLease_快速前后台同jobAttach不重启() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let llm = FakeLLM(responses: [finalClaims], delayNanos: 200_000_000)
        let fixture = makeLoopFixture(dir: dir, llm: llm, executor: FakeExecutor())
        let client = FakeBackgroundTaskClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, backgroundTaskClient: client)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let run = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        // 先等执行登记（否则 sceneDidEnterBackground 可能只看到空注册表）
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)
        await scheduler.sceneDidEnterBackground()
        XCTAssertEqual(client.activeLeaseCount, 1)

        let expired = await scheduler.sceneWillEnterForeground()
        XCTAssertFalse(expired, "未到期快速回前台不应视为 expiration")
        XCTAssertTrue(client.didEnd, "回前台应归还后台时间")

        // 同 job 再触发 → attach 同一执行，不重启第二条 runLoop
        let attached = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let finalJob = try await run
        XCTAssertEqual(attached.state, .completed)
        XCTAssertEqual(finalJob.state, .completed)
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 1, "快速前后台不得重启第二条 runLoop，实际 \(callCount)")
    }

    /// §6.4/Phase 2 复核：冷启动带旧 generation 的 orphan 由 resumeEligibleJobs 重新 acquire 接管。
    func testLease_冷启动orphan经resumeEligibleJobs新generation接管() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let fixture = makeLoopFixture(dir: dir, llm: FakeLLM(responses: [finalClaims]), executor: FakeExecutor())
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)
        try await fixture.runtime.pauseForBackground(now: now)

        // 模拟旧进程遗留的 generation（orphan）
        guard var orphan = try await fixture.jobStore.load().first(where: { $0.id == job.id }) else {
            XCTFail("job 应存在"); return
        }
        orphan.executionGeneration = 7
        try await fixture.jobStore.upsert(orphan)

        let resumed = try await scheduler.resumeEligibleJobs(
            trigger: .appLaunch, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(resumed, 1, "orphan 应被恢复")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.executionGeneration, 8,
                       "orphan 旧 generation(7) 应由新 acquire(8) 接管，实际 \(String(describing: stored?.executionGeneration))")
    }
}
