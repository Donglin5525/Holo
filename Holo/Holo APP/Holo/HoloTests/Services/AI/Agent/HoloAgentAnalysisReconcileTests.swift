//
//  HoloAgentAnalysisReconcileTests.swift
//  HoloTests
//
//  回归：跨域深度分析「发送后卡死被强杀，重进聊天页永远显示分析中」。
//  根因两个：
//    ① 消息先落「分析中」、job 后落盘——强杀落在窗口内时消息无 job 背书，
//       一次性孤儿清理（180s 宽限、仅页面重建时跑）接不住；
//    ② job 停在 running/waitingForLLM 落盘态且无活跃执行时，唯一会查截止的
//       refreshLiveProgress 只在 sendMessage 存活期间被调用，重进后无人触发。
//  修复：页面驻留对账 reconcileStalledAnalysisMessages（含无 job 宽限与超截止终结）。
//  活跃执行守卫（hasActiveExecution 为 true 时跳过终结）由 Scheduler 的
//  activeTasks 注册表保证，无法从外部注入活跃 Task，不在此单测覆盖。
//

import XCTest
@testable import Holo

@MainActor
final class HoloAgentAnalysisReconcileTests: XCTestCase {

    // MARK: - Fakes（与 HoloAgentSchedulerTests 对齐的最小闭环）

    private actor FakeLedger: HoloEvidenceLedgerProtocol {
        private var records: [HoloEvidenceRecord] = []
        func load() -> [HoloEvidenceRecord] { records }
        func upsert(_ newRecords: [HoloEvidenceRecord]) { records.append(contentsOf: newRecords) }
    }

    private actor FakeLLM: HoloAgentLLMClientProtocol {
        func next(messages: [HoloAgentMessage]) async throws -> String { "" }
        func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String { "" }
    }

    /// 恒抛指定错误的 LLM（步锁冲突/网络故障等注入用）。
    private actor ThrowingLLM: HoloAgentLLMClientProtocol {
        let error: Error
        init(error: Error) { self.error = error }
        func next(messages: [HoloAgentMessage]) async throws -> String { throw error }
        func next(messages: [HoloAgentMessage], step: HoloAgentLLMRequestRecord?) async throws -> String { throw error }
    }

    private actor FakeExecutor: HoloAgentToolExecuting {
        func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
            HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .empty,
                coverage: nil, metrics: [], events: [], warnings: [], error: nil, sensitivity: .normal
            )
        }
        func promptDescription() async -> String { "" }
    }

    private struct ServiceFixture {
        let service: HoloAgentAnalysisService
        let scheduler: HoloAgentScheduler
        let jobStore: HoloAgentJobStore
    }

    private func makeServiceFixture(
        llm: HoloAgentLLMClientProtocol = FakeLLM()
    ) -> ServiceFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-reconcile-test-\(UUID().uuidString)")
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
        let runtime = HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore,
            llmClient: llm,
            toolExecutor: FakeExecutor()
        )
        let scheduler = HoloAgentScheduler(runtime: runtime)
        return ServiceFixture(
            service: HoloAgentAnalysisService(runtime: runtime, scheduler: scheduler),
            scheduler: scheduler,
            jobStore: jobStore
        )
    }

    /// 建一条「分析中」加载态消息：intent=query_analysis、无 analysisContext、isStreaming。
    private func makeHangingAnalysisMessage(in repo: ChatMessageRepository) -> UUID {
        let userMessageId = repo.addMessage(role: "user", content: "把我的各类生活数据放在一起做一次深度分析")
        let messageId = repo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)
        repo.setAnalysisLoadingState(messageId, intent: "query_analysis", analysisContext: nil)
        return messageId
    }

    /// 停在 waitingForLLM、已超绝对截止、无活跃执行的强杀遗留 job。
    private func makeStaleWaitingJob(sourceMessageID: UUID) -> HoloAgentJob {
        let stale = Date().addingTimeInterval(-HoloAgentJob.absoluteDeadlineInterval - 60)
        return HoloAgentJob(
            id: UUID().uuidString,
            type: .deepAnalysis,
            userQuestion: "跨域分析",
            trigger: .userQuestion,
            state: .waitingForLLM,
            currentStep: .executeTools,
            createdAt: stale,
            updatedAt: stale,
            lastForegroundRunAt: nil,
            timeRange: nil,
            budget: HoloAgentBudget.normalDeep(),
            checkpointID: nil,
            resultID: nil,
            errorSummary: nil,
            deviceID: nil,
            sourceMessageID: sourceMessageID,
            absoluteDeadline: stale
        )
    }

    override func setUp() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
    }

    override func tearDown() async throws {
        ChatMessageRepository.shared.clearAllMessages()
    }

    // MARK: - 无 job 悬挂

    /// 强杀发生在 job 首次落盘之前：消息已落「分析中」但没有 job 背书，
    /// 超过宽限后对账应落地「深度分析已中断」，而不是永远转圈。
    func testNoJobHangingMessageFinalizedAfterGrace() async {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)

        // now 推到宽限期之外，模拟「强杀后过了一阵才重进」
        let didChange = await fixture.service.reconcileStalledAnalysisMessages(
            repository: repo,
            now: Date().addingTimeInterval(200)
        )

        XCTAssertTrue(didChange)
        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.isStreaming ?? true, "无 job 悬挂消息超过宽限后应落地终态")
        XCTAssertTrue(
            message?.content.hasPrefix("深度分析已中断") ?? false,
            "终态文案应明确中断，实际：\(message?.content ?? "")"
        )
    }

    /// 宽限期内（job 可能只是还没落盘，发送流程仍在跑）不得误杀。
    func testFreshNoJobMessageKeptWithinGrace() async {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)

        let didChange = await fixture.service.reconcileStalledAnalysisMessages(
            repository: repo,
            now: Date().addingTimeInterval(10)
        )

        XCTAssertFalse(didChange)
        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertTrue(message?.isStreaming ?? false, "宽限期内不得把发送中的分析误判为中断")
    }

    // MARK: - 云端轨道豁免（2026-09-08 假失败「分析启动前被中断」修复）

    /// 云端深度分析刻意不落本地 job、真实耗时可达 6-10 分钟：在途期间（有
    /// HoloCloudAnalysisService 注册表背书）不得按「无 job 超 90s」判「没真正开始」。
    /// 注册表本身无法注入，经 reconcile 的查询插槽模拟「云端在途」。
    func testLiveCloudTaskExemptedFromNeverStartedFinalization() async {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)

        let didChange = await fixture.service.reconcileStalledAnalysisMessages(
            repository: repo,
            now: Date().addingTimeInterval(200),
            hasLiveCloudTask: { [messageId] in $0 == messageId }
        )

        XCTAssertFalse(didChange)
        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertTrue(message?.isStreaming ?? false, "云端在途消息不得被对账落地为中断")
    }

    // MARK: - 有 job 超截止

    /// job 停在 waitingForLLM 落盘态（强杀时正在等模型响应）、已超绝对截止、
    /// 进程内无活跃执行：对账应终结 job 并落地「已中断」。
    func testDeadlineExceededJobWithoutActiveExecutionFinalized() async throws {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)
        let job = makeStaleWaitingJob(sourceMessageID: messageId)
        try await fixture.jobStore.upsert(job)

        let didChange = await fixture.service.reconcileStalledAnalysisMessages(repository: repo)

        XCTAssertTrue(didChange)
        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertFalse(message?.isStreaming ?? true, "超截止遗留 job 对应的消息应落地终态")
        XCTAssertTrue(message?.content.hasPrefix("深度分析已中断") ?? false)
        let persistedJob = try await fixture.jobStore.load().first(where: { $0.id == job.id })
        XCTAssertEqual(persistedJob?.state, .failed, "超截止且无活跃执行的 job 应被终结为 failed")
    }

    /// 无悬挂消息时对账应零成本返回。
    func testNoCandidatesIsNoop() async {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let didChange = await fixture.service.reconcileStalledAnalysisMessages(repository: repo)
        XCTAssertFalse(didChange)
    }

    // MARK: - 活跃态停滞兜底（2026-09-08 恢复后执行体挂死卡死回归）

    /// 停在 running、updatedAt 停滞超窗（未超绝对截止）：对账应落 failed 终态，
    /// 消息如实显示中断。实测事故形态：恢复后的执行体在发请求前挂死、零进展，
    /// 消息永远停在「思考中」无人收尾。
    func testStalledActiveJobFinalizedAfterStaleness() async throws {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)
        let now = Date()
        let stalled = HoloAgentJob(
            id: UUID().uuidString,
            type: .deepAnalysis,
            userQuestion: "分析近半年电费趋势",
            trigger: .userQuestion,
            state: .running,
            currentStep: .executeTools,
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-240),
            lastForegroundRunAt: nil,
            timeRange: nil,
            budget: HoloAgentBudget.normalDeep(),
            checkpointID: nil,
            resultID: nil,
            errorSummary: nil,
            deviceID: nil,
            sourceMessageID: messageId,
            absoluteDeadline: now.addingTimeInterval(1800)
        )
        try await fixture.jobStore.upsert(stalled)

        let didChange = await fixture.service.reconcileStalledAnalysisMessages(repository: repo)

        XCTAssertTrue(didChange)
        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertFalse(message?.isStreaming ?? true, "活跃态停滞超窗应落地终态")
        XCTAssertTrue(message?.content.hasPrefix("深度分析已中断") ?? false)
        let persisted = try await fixture.jobStore.load().first(where: { $0.id == stalled.id })
        XCTAssertEqual(persisted?.state, .failed, "停滞活跃 job 应被终结为 failed")
    }

    /// 活跃态但进展正常（updatedAt 新鲜）不得被停滞兜底误杀。
    func testFreshActiveJobNotFinalizedAsStalled() async throws {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture()
        let messageId = makeHangingAnalysisMessage(in: repo)
        let now = Date()
        let fresh = HoloAgentJob(
            id: UUID().uuidString,
            type: .deepAnalysis,
            userQuestion: "分析近半年电费趋势",
            trigger: .userQuestion,
            state: .running,
            currentStep: .executeTools,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-10),
            lastForegroundRunAt: nil,
            timeRange: nil,
            budget: HoloAgentBudget.normalDeep(),
            checkpointID: nil,
            resultID: nil,
            errorSummary: nil,
            deviceID: nil,
            sourceMessageID: messageId,
            absoluteDeadline: now.addingTimeInterval(1800)
        )
        try await fixture.jobStore.upsert(fresh)

        _ = await fixture.service.reconcileStalledAnalysisMessages(repository: repo)

        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertTrue(message?.isStreaming ?? false, "进展正常的活跃 job 不得被对账终结")
        let persisted = try await fixture.jobStore.load().first(where: { $0.id == fresh.id })
        XCTAssertEqual(persisted?.state, .running)
    }

    // MARK: - STEP_IN_PROGRESS 退避耗尽落终态（2026-09-08 409 卡死回归）

    /// 服务端步骤锁持续冲突（APIClient 独立退避 3 次耗尽后上抛）：runLoop 必须把
    /// job 落成 failed 终态。曾静默上抛导致 job 停在 waitingForLLM、消息永远「思考中」。
    func testStepInProgressExhaustionFailsJobTerminally() async throws {
        let repo = ChatMessageRepository.shared
        let fixture = makeServiceFixture(llm: ThrowingLLM(
            error: APIError.stepInProgress("Step is currently in progress")
        ))
        let userMessageId = repo.addMessage(role: "user", content: "分析近半年电费趋势")
        let messageId = repo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)

        let job = try await fixture.scheduler.start(
            question: "分析近半年电费趋势",
            systemTemplate: "",
            toolDescriptions: "",
            sourceMessageID: messageId
        )

        XCTAssertEqual(job.state, .failed, "409 退避耗尽应落 failed 终态，实际：\(job.state.rawValue)")
        XCTAssertTrue(job.errorSummary?.contains("重新发起") ?? false)
    }
}
