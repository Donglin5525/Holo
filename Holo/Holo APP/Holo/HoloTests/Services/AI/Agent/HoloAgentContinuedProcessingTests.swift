//
//  HoloAgentContinuedProcessingTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 6（§9，L2 持续执行）
//  iOS 26 Continued Processing 状态/调度回归（fake client，不替代真机验证）：
//  - 资格矩阵（版本/trigger/consent/开关/已有 P0 持有）
//  - .fail 策略：接纳→continued 租约接管同 job 单 Task；拒绝→回落 foreground/legacy
//  - 进度单调不回退、提前完成补齐、副标题无敏感内容
//  - 系统取消 → paused + 来源，不自动复活；明确动作接管
//  - 开关依赖：step 幂等关 → continued 不可开
//

import XCTest
@testable import Holo

final class HoloAgentContinuedProcessingTests: XCTestCase {

    // MARK: - Fakes

    /// fake 系统持续处理任务句柄
    private nonisolated final class FakeContinuedTask: HoloContinuedTask {
        let identifier: String
        // 使用独立进度对象，避免测试进程里的 XCTest/系统 Progress 隐式父子关系
        // 在跨用例释放时污染 fake 生命周期（iOS 26.3 Simulator 会触发非法释放）。
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        var expirationHandler: (() -> Void)?
        private(set) var updates: [(title: String, subtitle: String)] = []
        private(set) var completedSuccess: Bool?

        init(identifier: String) { self.identifier = identifier }

        func updateTitle(_ title: String, subtitle: String) {
            updates.append((title, subtitle))
        }

        func setTaskCompleted(success: Bool) {
            completedSuccess = success
        }

        /// 模拟系统结束（expiration/取消）
        @MainActor
        func expire() { expirationHandler?() }
    }

    /// fake 调度器：可脚本化「立即接纳/拒绝」，记录注册/提交/取消
    private nonisolated final class FakeContinuedClient: HoloContinuedProcessingClient {
        var acceptRegistrations = true
        var acceptRequests = true
        var launchesImmediately = true
        private(set) var registrationAttempts: [String] = []
        private(set) var registered: [String] = []
        private(set) var submitted: [HoloContinuedTaskRequest] = []
        private(set) var cancelled: [String] = []
        private(set) var lastTask: FakeContinuedTask?
        private var launchHandlers: [String: (any HoloContinuedTask) -> Void] = [:]

        struct SubmitError: Error {}

        func register(
            forTaskWithIdentifier identifier: String,
            launchHandler: @escaping (any HoloContinuedTask) -> Void
        ) -> Bool {
            registrationAttempts.append(identifier)
            guard acceptRegistrations else { return false }
            launchHandlers[identifier] = launchHandler
            if !registered.contains(identifier) {
                registered.append(identifier)
            }
            return true
        }

        func submit(_ request: HoloContinuedTaskRequest) throws {
            submitted.append(request)
            guard acceptRequests else { throw SubmitError() }
            if launchesImmediately {
                launch(request)
            }
        }

        @MainActor
        func launchLastSubmitted() {
            guard let request = submitted.last else { return }
            launch(request)
        }

        @MainActor
        private func launch(_ request: HoloContinuedTaskRequest) {
            let task = FakeContinuedTask(identifier: request.identifier)
            lastTask = task
            launchHandlers[request.identifier]?(task)
        }

        func cancel(taskRequestWithIdentifier identifier: String) {
            cancelled.append(identifier)
        }
    }

    private actor FakeLLM: HoloAgentLLMClientProtocol {
        private let responses: [String]
        private let delayNanos: UInt64
        private(set) var callCount = 0
        init(responses: [String], delayNanos: UInt64 = 0) {
            self.responses = responses
            self.delayNanos = delayNanos
        }
        func next(messages: [HoloAgentMessage]) async throws -> String {
            let index = callCount
            callCount += 1
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            return responses[min(index, responses.count - 1)]
        }
    }

    private actor FakeExecutor: HoloAgentToolExecuting {
        func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
            HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .success,
                coverage: nil, metrics: [], events: [], warnings: [], error: nil
            )
        }
        func promptDescription() async -> String { "" }
    }

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

    // MARK: - Helpers

    private struct Fixture {
        let runtime: HoloLocalAgentRuntime
        let jobStore: HoloAgentJobStore
        let checkpointStore: HoloAgentCheckpointStore
    }

    private func makeFixture(dir: URL, llm: HoloAgentLLMClientProtocol) -> Fixture {
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let jobStore = HoloAgentJobStore(directory: dir)
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: FakeLedger(),
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: HoloAgentResultStore(directory: dir)
        )
        let runtime = HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            llmClient: llm,
            toolExecutor: FakeExecutor()
        )
        return Fixture(runtime: runtime, jobStore: jobStore, checkpointStore: checkpointStore)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-continued-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    /// 打开 continued 所需的全部开关与 consent，测试结束自动还原
    private func enableContinuedFlags(consent: Bool = true) {
        let settings = HoloMemorySettings.shared
        let originalStep = settings.agentStepIdempotencyEnabled
        let originalContinued = settings.agentContinuedProcessingEnabled
        let originalConsent = HoloAIDataProcessingConsent.shared.isGranted
        settings.agentStepIdempotencyEnabled = true
        settings.agentContinuedProcessingEnabled = true
        if consent { HoloAIDataProcessingConsent.shared.grant() }
        addTeardownBlock {
            settings.agentContinuedProcessingEnabled = originalContinued
            settings.agentStepIdempotencyEnabled = originalStep
            if originalConsent {
                HoloAIDataProcessingConsent.shared.grant()
            } else {
                HoloAIDataProcessingConsent.shared.revoke()
            }
        }
    }

    private let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#

    // MARK: - §9.1 资格矩阵（纯函数）

    func test资格矩阵_全条件满足才可() {
        // 全满足
        XCTAssertTrue(HoloAgentContinuedEligibility.isEligible(
            trigger: .userQuestion, clientAvailable: true, consentGranted: true,
            flagEnabled: true, hasActiveContinuedLease: false
        ))
        // iOS 低版本（client 不可用）
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .userQuestion, clientAvailable: false, consentGranted: true,
            flagEnabled: true, hasActiveContinuedLease: false
        ), "iOS 26 以下不得使用")
        // 非用户发起（Observer/定时/自动被 trigger 门槛排除）
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .observerTier2, clientAvailable: true, consentGranted: true,
            flagEnabled: true, hasActiveContinuedLease: false
        ), "Observer 不得使用 continued")
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .memoryGalleryRefresh, clientAvailable: true, consentGranted: true,
            flagEnabled: true, hasActiveContinuedLease: false
        ), "定时刷新不得使用 continued")
        // 未同意 AI 数据处理
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .userQuestion, clientAvailable: true, consentGranted: false,
            flagEnabled: true, hasActiveContinuedLease: false
        ), "未同意数据处理不得使用")
        // 开关关闭
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .userQuestion, clientAvailable: true, consentGranted: true,
            flagEnabled: false, hasActiveContinuedLease: false
        ))
        // 已有 P0 持有 continued 执行权
        XCTAssertFalse(HoloAgentContinuedEligibility.isEligible(
            trigger: .userQuestion, clientAvailable: true, consentGranted: true,
            flagEnabled: true, hasActiveContinuedLease: true
        ), "已有 P0 持有时不得再申请")
    }

    /// §13.2 依赖顺序：step 幂等未开 → continued 强制为关（不能绕过后一个单独开启）。
    func test开关依赖_step幂等关则continued不可开() {
        let settings = HoloMemorySettings.shared
        let originalStep = settings.agentStepIdempotencyEnabled
        let originalContinued = settings.agentContinuedProcessingEnabled
        settings.agentStepIdempotencyEnabled = false
        settings.agentContinuedProcessingEnabled = true
        addTeardownBlock {
            settings.agentContinuedProcessingEnabled = originalContinued
            settings.agentStepIdempotencyEnabled = originalStep
        }
        XCTAssertFalse(HoloAIFeatureFlags.agentContinuedProcessingEnabled,
                       "step 幂等未开时 continued 必须强制为关")

        settings.agentStepIdempotencyEnabled = true
        XCTAssertTrue(HoloAIFeatureFlags.agentContinuedProcessingEnabled,
                      "依赖满足后才允许开启")
    }

    // MARK: - §9.3 .fail 策略集成

    /// 系统立即接纳 → continued 租约接管同 job（单 Task），完成后 setTaskCompleted 且进度补齐。
    @MainActor
    func testContinued_接纳后接管同job并完成结束() async throws {
        enableContinuedFlags()
        let dir = makeTempDir()
        let llm = FakeLLM(responses: [finalClaims])
        let fixture = makeFixture(dir: dir, llm: llm)
        let client = FakeContinuedClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, continuedClient: client)

        let job = try await scheduler.createAndRun(HoloAgentStartRequest(
            question: "q", systemTemplate: "s", toolDescriptions: "t"
        ))
        XCTAssertEqual(job.state, .completed)

        // 提交了一次 .fail 请求，identifier 绑定完整 jobID（每个具体工作唯一）
        XCTAssertEqual(client.submitted.count, 1)
        XCTAssertEqual(client.submitted.first?.strategy, .fail)
        XCTAssertTrue(client.submitted.first?.identifier.hasSuffix(job.id) == true,
                      "identifier 应绑定完整 jobID，实际 \(client.submitted.first?.identifier ?? "nil")")
        XCTAssertEqual(client.submitted.first?.title, "正在完成 Holo 深度分析",
                       "标题必须是固定通用文案（§7.4）")

        // 系统任务被启动且结束时 setTaskCompleted(success: true)，进度直接补齐
        let task = try XCTUnwrap(client.lastTask)
        XCTAssertEqual(task.completedSuccess, true)
        XCTAssertEqual(task.progress.totalUnitCount, task.progress.completedUnitCount,
                       "提前完成直接补齐进度，不伪造中间百分比")
        XCTAssertGreaterThan(task.progress.totalUnitCount, 0)
        // 副标题只来自固定模板（通用阶段，无敏感内容）
        for update in task.updates {
            XCTAssertEqual(update.title, "正在完成 Holo 深度分析")
            XCTAssertTrue(
                update.subtitle == "正在整理证据" || update.subtitle.hasPrefix("第 "),
                "副标题必须是通用阶段文案，实际：\(update.subtitle)"
            )
        }
        // 同 job 只有一个执行：LLM 恰好一轮
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 1)
    }

    /// 系统不接纳（.fail 抛错）→ 回落 foreground，切后台改绑 legacy 租约（§9.3 fallback）。
    @MainActor
    func testContinued_不接纳回落foreground并切后台转legacy() async throws {
        enableContinuedFlags()
        let dir = makeTempDir()
        let llm = FakeLLM(responses: [finalClaims], delayNanos: 150_000_000)
        let fixture = makeFixture(dir: dir, llm: llm)
        let client = FakeContinuedClient()
        client.acceptRequests = false
        let bgClient = FakeBackgroundTaskClient()
        let scheduler = HoloAgentScheduler(
            runtime: fixture.runtime,
            backgroundTaskClient: bgClient,
            continuedClient: client
        )
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let run = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await llm.callCount == 1 }
        XCTAssertTrue(llmStarted)
        // continued 未接纳：提交了但被拒，系统任务未启动
        XCTAssertEqual(client.submitted.count, 1)
        XCTAssertNil(client.lastTask, "未接纳不得启动系统任务")

        // 切后台：该 job 不是 continued 租约 → 改绑 legacy（fallback 完整链路）
        await scheduler.sceneDidEnterBackground()
        XCTAssertEqual(bgClient.activeLeaseCount, 1, "未获 continued 接纳时应回落 legacy 租约")

        let finalJob = try await run
        XCTAssertEqual(finalJob.state, .completed)
    }

    /// 进度单调不回退 + retry 不增加完成单位（§9.4）。
    @MainActor
    func testContinued_进度单调且retry不加单位() async throws {
        let client = FakeContinuedClient()
        let lease = HoloAgentContinuedProcessingLease(
            jobID: "job-progress-test",
            client: client,
            onSystemEnded: { _ in }
        )
        XCTAssertTrue(lease.acquire())
        // 系统启动是异步的（launchHandler 经 MainActor 派发），先等 launch 完成再上报
        let launched = await waitUntil { lease.didLaunch }
        XCTAssertTrue(launched, "acquire 后系统应立即启动（.fail 被接纳）")
        let task = try XCTUnwrap(client.lastTask)

        let baseJob = HoloAgentJob(
            id: "job-progress-test", type: .deepAnalysis, userQuestion: "q",
            trigger: .userQuestion, state: .running, currentStep: .executeTools,
            createdAt: Date(), updatedAt: Date(),
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: Date()),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
        func snapshot(consumedRounds: Int, consumedBatches: Int) -> HoloAgentProgressSnapshot {
            var job = baseJob
            job.budget.consumedLLMRounds = consumedRounds
            job.budget.consumedToolBatches = consumedBatches
            return HoloAgentProgressSnapshot(job: job)
        }

        await lease.report(snapshot(consumedRounds: 2, consumedBatches: 1))
        XCTAssertEqual(task.progress.completedUnitCount, 3)
        // 回退输入（如 retry 后重复上报旧进度）不得让进度倒退
        await lease.report(snapshot(consumedRounds: 1, consumedBatches: 0))
        XCTAssertEqual(task.progress.completedUnitCount, 3, "progress 单调不回退")
        // 完成时补齐并结束
        await lease.finish(success: true)
        XCTAssertEqual(task.progress.completedUnitCount, task.progress.totalUnitCount)
        XCTAssertEqual(task.completedSuccess, true)
        XCTAssertTrue(client.cancelled.isEmpty, "已启动任务应通过 setTaskCompleted 结束，不再取消 pending request")
    }

    /// 业务失败不能伪装成 100% 完成；保留最后真实进度并以失败闭合系统任务。
    @MainActor
    func testContinued_失败结束保留真实进度() async throws {
        let client = FakeContinuedClient()
        let initial = HoloAgentProgressSnapshot(
            jobID: "failed-progress", state: .waitingForLLM,
            totalUnitCount: 10, completedUnitCount: 2, generation: 1
        )
        let lease = HoloAgentContinuedProcessingLease(
            jobID: "failed-progress",
            client: client,
            initialProgress: initial,
            onSystemEnded: { _ in }
        )

        XCTAssertTrue(lease.acquire())
        let task = try XCTUnwrap(client.lastTask)
        await lease.finish(success: false)

        XCTAssertEqual(task.progress.completedUnitCount, 2)
        XCTAssertEqual(task.progress.totalUnitCount, 10)
        XCTAssertEqual(task.completedSuccess, false)
    }

    /// register 返回 false 表示系统/Info.plist 拒绝，不得继续 submit 后伪装为已接管。
    @MainActor
    func testContinued_注册失败不提交并回落() async {
        let client = FakeContinuedClient()
        client.acceptRegistrations = false
        let lease = HoloAgentContinuedProcessingLease(
            jobID: "job-register-rejected",
            client: client,
            onSystemEnded: { _ in }
        )

        XCTAssertFalse(lease.acquire())
        XCTAssertEqual(client.registrationAttempts.count, 1)
        XCTAssertTrue(client.submitted.isEmpty)
    }

    /// 同一 job 暂停后手动继续会再次 acquire，但系统 identifier 只能注册一次；业务 handler 更新到新 lease。
    @MainActor
    func testContinued_同job再次申请复用系统注册() async throws {
        let client = FakeContinuedClient()
        let first = HoloAgentContinuedProcessingLease(
            jobID: "same-job-resume",
            client: client,
            onSystemEnded: { _ in }
        )
        XCTAssertTrue(first.acquire())
        await first.finish(success: false)

        let second = HoloAgentContinuedProcessingLease(
            jobID: "same-job-resume",
            client: client,
            onSystemEnded: { _ in }
        )
        XCTAssertTrue(second.acquire())
        let launched = await waitUntil { second.didLaunch }
        XCTAssertTrue(launched)
        await second.finish(success: true)

        XCTAssertEqual(client.registrationAttempts.count, 2, "两次 lease 都会表达注册意图")
        XCTAssertEqual(client.registered.count, 1, "底层系统 identifier 只能注册一次")
        XCTAssertEqual(client.submitted.count, 2)
        XCTAssertEqual(client.lastTask?.completedSuccess, true)
    }

    /// submit 已成功但系统 launch 回调晚于业务完成时，晚到的任务也必须立即闭合。
    @MainActor
    func testContinued_晚到launch仍完成系统任务() async throws {
        let client = FakeContinuedClient()
        client.launchesImmediately = false
        let initial = HoloAgentProgressSnapshot(
            jobID: "late-launch", state: .running,
            totalUnitCount: 10, completedUnitCount: 2, generation: 1
        )
        let lease = HoloAgentContinuedProcessingLease(
            jobID: "late-launch",
            client: client,
            initialProgress: initial,
            onSystemEnded: { _ in }
        )

        XCTAssertTrue(lease.acquire())
        await lease.finish(success: true)
        XCTAssertEqual(client.cancelled.count, 1, "launch 未到时先撤销 pending request")

        // 模拟取消与 launch 交错：即使 launch 仍然到达，也要补 setTaskCompleted。
        client.launchLastSubmitted()
        let completed = await waitUntil { client.lastTask?.completedSuccess == true }
        XCTAssertTrue(completed)
        let task = try XCTUnwrap(client.lastTask)
        XCTAssertEqual(task.progress.totalUnitCount, 10)
        XCTAssertEqual(task.progress.completedUnitCount, 10)
    }

    /// 系统任务一启动就要有真实总量和当前量，不能等第一轮 LLM 完成后才首次设置 progress。
    @MainActor
    func testContinued_启动即初始化真实进度() async throws {
        let client = FakeContinuedClient()
        let initial = HoloAgentProgressSnapshot(
            jobID: "initial-progress", state: .waitingForLLM,
            totalUnitCount: 10, completedUnitCount: 2, generation: 3
        )
        let lease = HoloAgentContinuedProcessingLease(
            jobID: "initial-progress",
            client: client,
            initialProgress: initial,
            onSystemEnded: { _ in }
        )

        XCTAssertTrue(lease.acquire())
        let launched = await waitUntil { lease.didLaunch }
        XCTAssertTrue(launched)
        let task = try XCTUnwrap(client.lastTask)
        XCTAssertEqual(task.progress.totalUnitCount, 10)
        XCTAssertEqual(task.progress.completedUnitCount, 2)
        XCTAssertEqual(task.updates.last?.subtitle, "第 2 轮分析")
        await lease.finish(success: true)
    }

    /// UUID 前缀相同也必须生成不同系统 identifier，避免误取消另一个 job。
    func testContinued_identifier使用完整job唯一标识() {
        let first = HoloAgentContinuedProcessingLease.identifier(for: "12345678-AAAA-BBBB-CCCC-000000000001")
        let second = HoloAgentContinuedProcessingLease.identifier(for: "12345678-AAAA-BBBB-CCCC-000000000002")
        XCTAssertNotEqual(first, second)
    }

    /// §9.5：系统取消 → job 落 paused + 来源（waitReason=.systemCapacity），不自动复活；明确动作接管。
    @MainActor
    func testContinued_系统取消落paused不自动复活() async throws {
        enableContinuedFlags()
        let dir = makeTempDir()
        // LLM 挂起：让系统取消发生在执行中
        let hangingLLM = HangingFakeLLM(responses: [finalClaims])
        let fixture = makeFixture(dir: dir, llm: hangingLLM)
        let client = FakeContinuedClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, continuedClient: client)
        let now = Date()
        let job = try await fixture.runtime.startAnalysisJob(question: "q", now: now)

        async let run = scheduler.runOrAttach(
            jobID: job.id, reason: .userInitiated, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        let llmStarted = await waitUntil { await hangingLLM.callCount == 1 }
        XCTAssertTrue(llmStarted)

        // 系统结束（expiration/取消）
        let task = try XCTUnwrap(client.lastTask)
        task.expire()

        let systemCompleted = await waitUntil { task.completedSuccess == false }
        XCTAssertTrue(systemCompleted, "expiration handler 必须向系统回报失败完成")

        let paused = await waitUntil {
            let stored = try? await fixture.jobStore.load().first { $0.id == job.id }
            return stored?.state == .paused
        }
        XCTAssertTrue(paused, "系统取消后 job 应落 paused")
        let stored = try await fixture.jobStore.load().first { $0.id == job.id }
        XCTAssertEqual(stored?.waitReason, .systemCapacity)
        XCTAssertNotNil(stored?.errorSummary, "必须记录来源（不静默）")

        // 不自动复活：resumeEligibleJobs 不接 paused
        await hangingLLM.release()
        do {
            _ = try await run
            XCTFail("被系统取消的执行不应正常返回")
        } catch {
            // CancellationError 为预期
        }
        let resumed = try await scheduler.resumeEligibleJobs(
            trigger: .foreground, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(resumed, 0, "paused 不得自动复活")

        // 用户明确动作（runOrAttach）可接管继续
        await hangingLLM.setHangNext(false)
        let continued = try await scheduler.runOrAttach(
            jobID: job.id, reason: .foregroundReturn, systemTemplate: "s", toolDescriptions: "t", now: now
        )
        XCTAssertEqual(continued.state, .completed, "明确动作接管后应从断点完成")
    }

    /// 非用户发起 job（Observer trigger）即使开关全开也不提交 continued 请求。
    @MainActor
    func testContinued_非用户发起不提交() async throws {
        enableContinuedFlags()
        let dir = makeTempDir()
        let llm = FakeLLM(responses: [finalClaims])
        let fixture = makeFixture(dir: dir, llm: llm)
        let client = FakeContinuedClient()
        let scheduler = HoloAgentScheduler(runtime: fixture.runtime, continuedClient: client)
        let job = try await scheduler.createAndRun(HoloAgentStartRequest(
            question: "q",
            trigger: .observerTier2,
            systemTemplate: "s",
            toolDescriptions: "t"
        ))
        XCTAssertEqual(job.trigger, .observerTier2, "创建链路必须保留 Observer 真实触发来源")
        XCTAssertEqual(job.lastResumeReason, .automaticInitiated, "自动任务不得记为用户主动发起")
        XCTAssertTrue(client.submitted.isEmpty, "Observer 任务不得提交 continued 请求")
    }

    /// 挂起型 fake LLM：第一次调用挂起直到放行（模拟系统取消发生在执行中）。
    private actor HangingFakeLLM: HoloAgentLLMClientProtocol {
        private let responses: [String]
        private var hangNext = true
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var callCount = 0

        init(responses: [String]) { self.responses = responses }

        func next(messages: [HoloAgentMessage]) async throws -> String {
            let index = callCount
            callCount += 1
            if hangNext {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    gate = continuation
                }
            }
            return responses[min(index, responses.count - 1)]
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        func setHangNext(_ value: Bool) {
            hangNext = value
        }
    }

    /// 与 SchedulerTests 同款的多租约 fake 后台任务 client
    @MainActor
    private final class FakeBackgroundTaskClient: HoloBackgroundTaskClient {
        private(set) var handlers: [Int: () -> Void] = [:]
        private(set) var endedIDs: [Int] = []
        private var nextID = 0
        var activeLeaseCount: Int { handlers.count }

        func beginBackgroundTask(named name: String,
                                 expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
            nextID += 1
            handlers[nextID] = expirationHandler
            return UIBackgroundTaskIdentifier(rawValue: nextID)
        }

        func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
            endedIDs.append(identifier.rawValue)
            handlers[identifier.rawValue] = nil
        }
    }
}
