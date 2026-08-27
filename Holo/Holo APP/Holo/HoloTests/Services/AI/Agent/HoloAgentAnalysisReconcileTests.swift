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
        let jobStore: HoloAgentJobStore
    }

    private func makeServiceFixture() -> ServiceFixture {
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
            llmClient: FakeLLM(),
            toolExecutor: FakeExecutor()
        )
        let scheduler = HoloAgentScheduler(runtime: runtime)
        return ServiceFixture(
            service: HoloAgentAnalysisService(runtime: runtime, scheduler: scheduler),
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
}
