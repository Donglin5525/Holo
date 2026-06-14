//
//  HoloLocalAgentRuntimeTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.5 Mock Runtime 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Persistence/*.swift> \
//    <Services/AI/Agent/HoloLocalAgentRuntime.swift> <Services/AI/Agent/HoloAgentRuntimeFactory.swift> \
//    <本测试> -o /tmp/holo_agent_runtime_test && /tmp/holo_agent_runtime_test
//

import Foundation

/// Runtime 测试专用内存 Evidence Ledger（独立命名，避免与其他测试文件联合编译时重复定义）。
actor RuntimeMockLedger: HoloEvidenceLedgerProtocol {
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

/// 多轮 loop 测试专用 fake LLM client：按顺序返回预设响应。
actor FakeAgentLLMClient: HoloAgentLLMClientProtocol {
    private let responses: [String]
    private(set) var messageBatches: [[HoloAgentMessage]] = []
    private(set) var callCount = 0
    init(responses: [String]) { self.responses = responses }
    func next(messages: [HoloAgentMessage]) async throws -> String {
        messageBatches.append(messages)
        let response = responses[min(callCount, responses.count - 1)]
        callCount += 1
        return response
    }
}

/// 多轮 loop 测试专用 fake tool executor：返回成功空结果。
actor FakeToolExecutor: HoloAgentToolExecuting {
    func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
                           coverage: nil,
                           metrics: [
                            HoloMetric(metricKey: "finance.meal.nighttime_count", value: 5, unit: "次",
                                       baselineValue: 1, comparison: "increasing")
                           ],
                           events: [
                            HoloEvidenceEvent(id: "event-1", occurredAt: Date(timeIntervalSince1970: 1000),
                                              metricKey: "finance.meal.nighttime_count",
                                              metricValue: 5, excerpt: "晚餐消费 5 次")
                           ],
                           warnings: [], error: nil)
    }

    func promptDescription() async -> String { "" }
}

@main
struct HoloLocalAgentRuntimeTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testStartMockJob_创建后进入running并写入初始checkpoint()
        try await testCompleteCurrentStep_plan完成后推进到executeTools()
        try await testResume_重启后从checkpoint对齐到当前step()
        try await testCancel_状态变为cancelled且resume不恢复执行()
        try await testRunLoop_needTools后finalClaims两轮完成()
        try await testRunLoop_工具结果进入下一轮LLM上下文且不用原生tool角色()
        try await testRunLoop_模型不收敛时用工具结果兜底完成()
        try await testPauseForBackground_运行中任务标记waitingForForeground()
        try await testResumeUnfinishedJobs_恢复未完成任务()
        try await test后台暂停后恢复并RunLoop完成()
        print("HoloLocalAgentRuntimeTests passed")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-runtime-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用临时目录构造一套隔离的 runtime + store，便于断言落盘内容。
    private static func makeRuntime(dir: URL)
        -> (runtime: HoloLocalAgentRuntime, jobStore: HoloAgentJobStore, checkpointStore: HoloAgentCheckpointStore) {
        let ledger = RuntimeMockLedger()
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
            checkpointStore: checkpointStore
        )
        return (runtime, jobStore, checkpointStore)
    }

    /// 构造带 LLM client + toolExecutor 的 runtime（多轮 loop 测试用）。
    private static func makeLoopRuntime(dir: URL, llmClient: HoloAgentLLMClientProtocol, toolExecutor: HoloAgentToolExecuting)
        -> (runtime: HoloLocalAgentRuntime, jobStore: HoloAgentJobStore, checkpointStore: HoloAgentCheckpointStore) {
        let ledger = RuntimeMockLedger()
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
            llmClient: llmClient,
            toolExecutor: toolExecutor
        )
        return (runtime, jobStore, checkpointStore)
    }

    // MARK: - 用例

    /// 创建 mock job 后应立即进入 running，并写入初始 checkpoint（step=plan, completedSteps 为空）。
    private static func testStartMockJob_创建后进入running并写入初始checkpoint() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = Date(timeIntervalSince1970: 1000)

        let job = try await fixture.runtime.startMockJob(question: "为什么最近开销变大？", now: now)

        expect(job.state == .running, "startMockJob 后 job 应进入 running，实际 \(job.state)")
        expect(job.currentStep == .plan, "初始 step 应为 plan，实际 \(job.currentStep)")
        expect(job.type == .debugMock, "mock job 类型应为 debugMock")
        expect(job.checkpointID != nil, "应回填 checkpointID")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint != nil, "应能读到初始 checkpoint")
        expect(checkpoint?.step == .plan, "初始 checkpoint step 应为 plan")
        expect(checkpoint?.completedSteps.isEmpty ?? false, "初始 checkpoint completedSteps 应为空")
        expect(checkpoint?.conversationState.isEmpty == false, "初始 checkpoint 应含 mock 消息")
    }

    /// 完成 plan step 后应推进到 executeTools，并写入新 checkpoint（completedSteps 含 plan）。
    private static func testCompleteCurrentStep_plan完成后推进到executeTools() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)

        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        let updated = try await fixture.runtime.completeCurrentStep(jobID: job.id, now: Date(timeIntervalSince1970: 2000))

        expect(updated.currentStep == .executeTools, "plan 完成后应推进到 executeTools，实际 \(updated.currentStep)")
        expect(updated.state == .running, "推进后仍应 running")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint?.step == .executeTools, "新 checkpoint step 应为 executeTools")
        expect(checkpoint?.completedSteps == [.plan], "completedSteps 应含 plan，实际 \(String(describing: checkpoint?.completedSteps))")
    }

    /// 模拟 app 重启（新 runtime 实例，同一磁盘目录），resume 应从最新 checkpoint 对齐 step。
    private static func testResume_重启后从checkpoint对齐到当前step() async throws {
        let dir = makeTempDir()

        // 第一次运行：start + 完成 plan（推进到 executeTools）
        let run1 = makeRuntime(dir: dir)
        let job = try await run1.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        _ = try await run1.runtime.completeCurrentStep(jobID: job.id, now: Date(timeIntervalSince1970: 2000))

        // 模拟重启：新 runtime 实例读取同一目录，resume 对齐 checkpoint
        let run2 = makeRuntime(dir: dir)
        let resumed = try await run2.runtime.resume(jobID: job.id, now: Date(timeIntervalSince1970: 3000))

        expect(resumed.currentStep == .executeTools, "resume 后应从 checkpoint 的 step(executeTools) 继续，实际 \(resumed.currentStep)")
        expect(resumed.state == .running, "resume 后应为 running")
        expect(resumed.checkpointID != nil, "resume 后应回填 checkpointID")
    }

    /// cancel 后状态为 cancelled，且 resume 不应恢复执行（保持 cancelled）。
    private static func testCancel_状态变为cancelled且resume不恢复执行() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))

        let cancelled = try await fixture.runtime.cancel(jobID: job.id, now: Date(timeIntervalSince1970: 2000))
        expect(cancelled.state == .cancelled, "cancel 后状态应为 cancelled")

        let stored = await fixture.jobStore.load().first { $0.id == job.id }
        expect(stored?.state == .cancelled, "落盘 job 状态应为 cancelled")

        // resume 一个 cancelled job 不应恢复执行
        let resumed = try await fixture.runtime.resume(jobID: job.id, now: Date(timeIntervalSince1970: 3000))
        expect(resumed.state == .cancelled, "cancelled job resume 不应恢复执行")
    }

    /// 多轮 loop：第 1 轮 need_tools，工具执行后第 2 轮 final_claims。
    private static func testRunLoop_needTools后finalClaims两轮完成() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查习惯","toolRequests":[{"id":"t1","tool":"habit","query":"negative_habit_control","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)

        let job = try await fixture.runtime.startMockJob(question: "最近习惯怎么样", now: Date(timeIntervalSince1970: 1000))
        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【habit】习惯工具",
            now: Date(timeIntervalSince1970: 2000)
        )

        let callCount = await client.callCount
        expect(callCount == 2, "应调用 LLM 两轮，实际 \(callCount)")
        expect(result.state == .completed, "runLoop 完成后应为 completed，实际 \(result.state.rawValue)")
        expect(result.budget.consumedLLMRounds == 2, "consumedLLMRounds 应为 2")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint?.completedToolResults.isEmpty == false, "checkpoint 应含工具执行结果")
    }

    /// 工具结果必须作为普通上下文进入下一轮 LLM，不能使用 OpenAI 原生 tool role。
    private static func testRunLoop_工具结果进入下一轮LLM上下文且不用原生tool角色() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"meal_spending","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)

        let job = try await fixture.runtime.startMockJob(question: "最近消费有什么变化", now: Date(timeIntervalSince1970: 1000))
        _ = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: Date(timeIntervalSince1970: 2000)
        )

        let batches = await client.messageBatches
        expect(batches.count == 2, "应调用 LLM 两轮，实际 \(batches.count)")
        let secondBatch = batches[1]
        expect(!secondBatch.contains(where: { $0.role == .toolResult }), "第二轮 LLM 上下文不应包含原生 toolResult 角色")
        let joinedContent = secondBatch.map(\.content).joined(separator: "\n")
        expect(joinedContent.contains("finance.meal.nighttime_count"), "第二轮 LLM 上下文应包含工具 metric")
        expect(joinedContent.contains("晚餐消费"), "第二轮 LLM 上下文应包含工具事件摘要")
    }

    /// 模型一直不输出 final_claims 时，已有工具结果应兜底产出保守结论，避免用户看到预算耗尽。
    private static func testRunLoop_模型不收敛时用工具结果兜底完成() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"meal_spending","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let more = #"{"status":"need_more_analysis","reasoning":"还需要继续分析","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, more, more, more, more])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)

        let job = try await fixture.runtime.startMockJob(question: "最近消费有什么变化", now: Date(timeIntervalSince1970: 1000))
        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: Date(timeIntervalSince1970: 2000)
        )

        expect(result.state == .completed, "模型不收敛但已有工具结果时应兜底完成，实际 \(result.state.rawValue)")
        expect(result.errorSummary == nil, "兜底完成不应留下 errorSummary")

        let savedResult = await fixture.runtime.loadLatestResult()
        expect(savedResult?.claims.isEmpty == false, "兜底完成应保存至少 1 条 claim")
        expect(savedResult?.summary.contains("晚间餐饮频次偏移") == true, "兜底 summary 应来自 pattern signal")
    }

    /// 进入后台：running 任务标记为 waitingForForeground。
    private static func testPauseForBackground_运行中任务标记waitingForForeground() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))

        try await fixture.runtime.pauseForBackground(now: Date(timeIntervalSince1970: 2000))

        let stored = await fixture.jobStore.load().first { $0.id == job.id }
        expect(stored?.state == .waitingForForeground, "进后台应标记 waitingForForeground，实际 \(stored?.state.rawValue ?? "nil")")
        expect(stored?.lastForegroundRunAt != nil, "应记录最后前台时间")
    }

    /// 回前台：恢复未结束（waitingForForeground）的任务。
    private static func testResumeUnfinishedJobs_恢复未完成任务() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        try await fixture.runtime.pauseForBackground(now: Date(timeIntervalSince1970: 2000))

        let count = try await fixture.runtime.resumeUnfinishedJobs(now: Date(timeIntervalSince1970: 3000))
        expect(count == 1, "应恢复 1 个任务，实际 \(count)")

        let stored = await fixture.jobStore.load().first { $0.id == job.id }
        expect(stored?.state == .running, "恢复后应为 running，实际 \(stored?.state.rawValue ?? "nil")")
    }

    /// 后台暂停 → 前台恢复 → runLoop 从 checkpoint 续跑完成（恢复语义端到端）。
    private static func test后台暂停后恢复并RunLoop完成() async throws {
        let dir = makeTempDir()
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))

        try await fixture.runtime.pauseForBackground(now: Date(timeIntervalSince1970: 2000))
        let resumed = try await fixture.runtime.resumeUnfinishedJobs(now: Date(timeIntervalSince1970: 3000))
        expect(resumed == 1, "应恢复 1 个任务")

        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "tools",
            now: Date(timeIntervalSince1970: 4000)
        )
        expect(result.state == .completed, "恢复后续跑应完成，实际 \(result.state.rawValue)")
    }
}
