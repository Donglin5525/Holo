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
    private(set) var requests: [HoloToolRequest] = []

    func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
        requests.append(request)
        if request.tool == "health", request.query == "sleep_summary" {
            let metrics = [
                HoloMetric(metricKey: "health.sleep.average_hours", value: 6.5, unit: "小时", baselineValue: 7, comparison: "较上期-0.5小时"),
                HoloMetric(metricKey: "health.sleep.recorded_nights", value: 7, unit: "晚", baselineValue: nil, comparison: nil),
                HoloMetric(metricKey: "health.sleep.low_days", value: 2, unit: "晚", baselineValue: nil, comparison: nil)
            ]
            let events = metrics.map { metric in
                HoloEvidenceEvent(id: "event-\(metric.metricKey)", occurredAt: Date(), metricKey: metric.metricKey,
                                  metricValue: metric.value, excerpt: "睡眠汇总：\(metric.metricKey) = \(metric.value ?? 0) \(metric.unit ?? "")")
            } + [HoloEvidenceEvent(id: "sleep-capability", occurredAt: Date(), metricKey: "health.sleep.capability",
                                   metricValue: 0, excerpt: "当前只能评估睡眠时长，不能完整判断睡眠质量")]
            return HoloDataToolResult(toolRequestID: request.id, tool: "health", status: .partial,
                                      coverage: HoloDataCoverage(coveredDays: 7, totalDays: 10, coverageRatio: 0.7, missingRanges: [], note: "7/10 晚"),
                                      metrics: metrics, events: events,
                                      warnings: [HoloToolWarning(code: "SLEEP_DURATION_ONLY", message: "当前只能评估睡眠时长，不能完整判断睡眠质量")],
                                      error: nil, sensitivity: .sensitive)
        }
        if request.tool == "health", request.query == "steps_summary" {
            let metrics = [
                HoloMetric(
                    metricKey: "health.steps.average",
                    value: 6990.8,
                    unit: "步",
                    baselineValue: nil,
                    comparison: nil
                ),
                HoloMetric(
                    metricKey: "health.steps.goal_met_days",
                    value: 1,
                    unit: "天",
                    baselineValue: nil,
                    comparison: nil
                )
            ]
            let events = metrics.map { metric in
                HoloEvidenceEvent(
                    id: "event-\(metric.metricKey)",
                    occurredAt: Date(),
                    metricKey: metric.metricKey,
                    metricValue: metric.value,
                    excerpt: "步数汇总：\(metric.metricKey) = \(metric.value ?? 0) \(metric.unit ?? "")"
                )
            }
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: "health",
                status: .success,
                coverage: HoloDataCoverage(
                    coveredDays: 28,
                    totalDays: 30,
                    coverageRatio: 28.0 / 30.0,
                    missingRanges: [],
                    note: "已读取 28/30 天健康数据"
                ),
                metrics: metrics,
                events: events,
                warnings: [],
                error: nil,
                sensitivity: .sensitive
            )
        }
        if request.dynamicPlan != nil {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .success,
                coverage: nil,
                metrics: [HoloMetric(metricKey: "dynamic.health_sleep.average_sleep.all", value: 7.2, unit: "小时", baselineValue: nil, comparison: nil, formula: "average(value)", sourceRecordIDs: ["sleep-1", "sleep-2"])],
                events: [HoloEvidenceEvent(id: "dynamic-average-sleep", occurredAt: Date(), metricKey: "dynamic.health_sleep.average_sleep.all", metricValue: 7.2, excerpt: "平均睡眠 7.2 小时", formula: "average(value)", sourceRecordIDs: ["sleep-1", "sleep-2"])],
                warnings: [],
                error: nil,
                sensitivity: .sensitive
            )
        }
        if request.query == "spending_breakdown" {
            return HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
                                      coverage: nil,
                                      metrics: [
                                        HoloMetric(metricKey: "finance.total.amount", value: 14598.83, unit: "元",
                                                   baselineValue: nil, comparison: nil),
                                        HoloMetric(metricKey: "finance.category.amount", value: 3516, unit: "元",
                                                   baselineValue: nil, comparison: "餐饮"),
                                        HoloMetric(metricKey: "finance.category.amount", value: 3156, unit: "元",
                                                   baselineValue: nil, comparison: "居住"),
                                        HoloMetric(metricKey: "finance.category.amount", value: 1525, unit: "元",
                                                   baselineValue: nil, comparison: "数码")
                                      ],
                                      events: [
                                        HoloEvidenceEvent(id: "event-total", occurredAt: nil,
                                                          metricKey: "finance.total.amount",
                                                          metricValue: 14598.83,
                                                          excerpt: "上月总支出：14598.83 元",
                                                          timeRange: request.timeRange),
                                        HoloEvidenceEvent(id: "event-category-meal", occurredAt: nil,
                                                          metricKey: "finance.category.amount",
                                                          metricValue: 3516,
                                                          excerpt: "上月分类去向：餐饮：3516 元（约 24%）",
                                                          timeRange: request.timeRange),
                                        HoloEvidenceEvent(id: "event-category-rent", occurredAt: nil,
                                                          metricKey: "finance.category.amount",
                                                          metricValue: 3156,
                                                          excerpt: "上月分类去向：居住：3156 元（约 22%）",
                                                          timeRange: request.timeRange),
                                        HoloEvidenceEvent(id: "event-category-digital", occurredAt: nil,
                                                          metricKey: "finance.category.amount",
                                                          metricValue: 1525,
                                                          excerpt: "上月分类去向：数码：1525 元（约 10%）",
                                                          timeRange: request.timeRange),
                                        HoloEvidenceEvent(id: "event-sample-rent", occurredAt: nil,
                                                          metricKey: "finance.transaction.sample",
                                                          metricValue: nil,
                                                          excerpt: "上月大额支出样例：6月29日 居住 房租 -¥3156",
                                                          timeRange: request.timeRange),
                                        HoloEvidenceEvent(id: "event-sample-digital", occurredAt: nil,
                                                          metricKey: "finance.transaction.sample",
                                                          metricValue: nil,
                                                          excerpt: "上月大额支出样例：6月16日 数码 MacBook 分期 -¥1525",
                                                          timeRange: request.timeRange)
                                      ],
                                      warnings: [], error: nil)
        }
        return HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
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
        try await testStartAnalysisJob_本月问题写入整月时间范围()
        try await testStartAnalysisJob_上个月问题写入上月整月时间范围()
        try await testStartAnalysisJob_显式月份问题写入对应自然月范围()
        try await testStartAnalysisJob_带年份月份问题写入指定年月范围()
        try await testRunLoop_上个月工具请求缺少范围时继承上月范围()
        try await testRunLoop_工具请求缺少范围时继承Job范围()
        try await testRunLoop_财务去向问题先强制查询账单拆分()
        try await testRunLoop_财务工具已返回但模型JSON解析失败时用工具结果完成()
        try await testRunLoop_工具结果进入下一轮LLM上下文且不用原生tool角色()
        try await testRunLoop_工具上下文使用全局唯一EvidenceID()
        try await testRunLoop_finalClaims必须经过Evidence校验()
        try await testRunLoop_模型不收敛时用工具结果兜底完成()
        try await testRunLoop_动态查询结果经过证据校验后完成()
        try await testRunLoop_睡眠质量降级仍输出完整可读结论()
        try await testRunLoop_步数兜底输出完整可读结论与覆盖范围()
        try await testPauseForBackground_运行中任务标记waitingForForeground()
        try await testResumeUnfinishedJobs_恢复未完成任务()
        try await test后台暂停后恢复并RunLoop完成()
        print("HoloLocalAgentRuntimeTests passed")
    }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
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
        let now = Date()

        let job = try await fixture.runtime.startMockJob(question: "最近习惯怎么样", now: now)
        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【habit】习惯工具",
            now: now.addingTimeInterval(1)
        )

        let callCount = await client.callCount
        expect(callCount == 2, "应调用 LLM 两轮，实际 \(callCount)")
        expect(result.state == .completed, "runLoop 完成后应为 completed，实际 \(result.state.rawValue)")
        expect(result.budget.consumedLLMRounds == 2, "consumedLLMRounds 应为 2")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint?.completedToolResults.isEmpty == false, "checkpoint 应含工具执行结果")
    }

    /// 用户明确说“本月/这个月”时，Agent job 必须落盘整月范围，不能回退到近 14 天。
    private static func testStartAnalysisJob_本月问题写入整月时间范围() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = makeDate(2026, 6, 30)

        let job = try await fixture.runtime.startAnalysisJob(
            question: "这个月都花了 1.4 万了？钱都花哪儿去了？分析一下",
            now: now
        )

        expect(job.timeRange?.label == "本月", "本月问题应写入 label=本月，实际 \(job.timeRange?.label ?? "nil")")
        expect(job.timeRange?.start == makeDate(2026, 6, 1), "本月 start 应为 6/1")
        expect(job.timeRange?.end == makeDate(2026, 7, 1), "本月 end 应为 7/1 exclusive，避免漏掉 6/30")
    }

    /// 跨月后用户说“上个月”时，Agent 必须查自然月上月，不能误用今天所在月。
    private static func testStartAnalysisJob_上个月问题写入上月整月时间范围() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = Date()

        let job = try await fixture.runtime.startAnalysisJob(
            question: "上个月都花了 1.4 万了？钱都花哪儿去了？分析一下",
            now: now
        )

        expect(job.timeRange?.label == "上月", "上个月问题应写入 label=上月，实际 \(job.timeRange?.label ?? "nil")")
        expect(job.timeRange?.start == makeDate(2026, 6, 1), "上个月 start 应为 6/1")
        expect(job.timeRange?.end == makeDate(2026, 7, 1), "上个月 end 应为 7/1 exclusive，避免漏掉 6/30")
    }

    /// 用户直接说“六月/6月”时，也应确定性落到对应自然月。
    private static func testStartAnalysisJob_显式月份问题写入对应自然月范围() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = Date()

        let job = try await fixture.runtime.startAnalysisJob(
            question: "六月都花了 1.4 万了？钱都花哪儿去了？分析一下",
            now: now
        )

        expect(job.timeRange?.label == "6月", "六月问题应写入 label=6月，实际 \(job.timeRange?.label ?? "nil")")
        expect(job.timeRange?.start == makeDate(2026, 6, 1), "六月 start 应为 6/1")
        expect(job.timeRange?.end == makeDate(2026, 7, 1), "六月 end 应为 7/1 exclusive")
    }

    /// 带年份的月份必须尊重用户给出的年份，不能按当前年份猜。
    private static func testStartAnalysisJob_带年份月份问题写入指定年月范围() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = makeDate(2026, 7, 1)

        let job = try await fixture.runtime.startAnalysisJob(
            question: "2025年6月都花哪儿去了？",
            now: now
        )

        expect(job.timeRange?.label == "2025年6月", "指定年月应保留年份，实际 \(job.timeRange?.label ?? "nil")")
        expect(job.timeRange?.start == makeDate(2025, 6, 1), "2025年6月 start 应为 2025/6/1")
        expect(job.timeRange?.end == makeDate(2025, 7, 1), "2025年6月 end 应为 2025/7/1 exclusive")
    }

    /// 即使 LLM 忘记给工具请求带 timeRange，“上个月”也要继承 job 的上月范围。
    private static func testRunLoop_上个月工具请求缺少范围时继承上月范围() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"spending_breakdown","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()
        let calendar = Calendar.current
        let currentMonth = calendar.dateInterval(of: .month, for: now)!
        let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonth.start)!

        let job = try await fixture.runtime.startAnalysisJob(question: "上个月钱花哪了", now: now)
        _ = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        let requests = await executor.requests
        expect(requests.count == 1, "应执行 1 次工具请求，实际 \(requests.count)")
        let actualRange = requests.first?.timeRange
        expect(actualRange?.label == "上月", "工具请求应继承上月范围，实际 \(String(describing: actualRange))")
        expect(actualRange?.start == previousMonthStart, "工具请求 start 应为上月首日")
        expect(actualRange?.end == currentMonth.start, "工具请求 end 应为本月首日 exclusive")
    }

    /// 即使 LLM toolRequest 没填 timeRange，runtime 也要把 job 范围注入工具请求。
    private static func testRunLoop_工具请求缺少范围时继承Job范围() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"spending_breakdown","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()
        let month = Calendar.current.dateInterval(of: .month, for: now)!

        let job = try await fixture.runtime.startAnalysisJob(question: "本月钱花哪了", now: now)
        let storedJob = await fixture.jobStore.load().first { $0.id == job.id }
        expect(storedJob?.timeRange?.label == "本月", "落盘 job 应保留本月范围，实际 \(String(describing: storedJob?.timeRange))")
        _ = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        let requests = await executor.requests
        expect(requests.count == 1, "应执行 1 次工具请求，实际 \(requests.count)")
        let actualRange = requests.first?.timeRange
        expect(actualRange?.label == "本月", "工具请求应继承本月范围，实际 \(String(describing: actualRange))")
        expect(requests.first?.timeRange?.start == month.start, "工具请求 start 应为本月首日")
        expect(requests.first?.timeRange?.end == month.end, "工具请求 end 应为下月首日 exclusive")
    }

    /// 总额去向问题不能等模型自觉请求工具：runtime 应先强制查 finance.spending_breakdown。
    private static func testRunLoop_财务去向问题先强制查询账单拆分() async throws {
        let dir = makeTempDir()
        let unsupportedFinal = #"{"status":"final_claims","reasoning":"模型跳过工具","toolRequests":[],"claims":[{"id":"c1","type":"observation","displayText":"系统目前无法获取对应的支出拆分数据","metricAssertions":[],"evidenceIDs":[],"prohibitedInferences":[],"confidence":0.5}],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [unsupportedFinal])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = makeDate(2026, 7, 1)

        let job = try await fixture.runtime.startAnalysisJob(
            question: "上个月花了 1.4 万？钱都花哪儿去了？分析一下",
            now: now
        )
        let result = try await fixture.runtime.runLoop(
            jobID: job.id,
            systemTemplate: "你是 Agent",
            toolDescriptions: "【finance】消费工具",
            now: now
        )

        let requests = await executor.requests
        expect(requests.first?.tool == "finance", "财务去向问题应先调用 finance 工具")
        expect(requests.first?.query == "spending_breakdown", "财务去向问题应强制 spending_breakdown")
        expect(requests.first?.timeRange?.start == makeDate(2026, 6, 1), "工具请求应使用上月首日")
        expect(requests.first?.timeRange?.end == makeDate(2026, 7, 1), "工具请求应使用本月首日 exclusive")
        expect(result.state == .completed, "即使模型跳过工具，也应基于工具事实完成")

        let savedResult = await fixture.runtime.loadLatestResult()
        expect(savedResult?.summary.contains("14598.83") == true, "最终摘要应来自工具返回的 14598.83，而不是空口无法获取")
        expect(savedResult?.summary.contains("餐饮") == true, "最终摘要必须回答钱花哪了，包含 Top 分类餐饮")
        expect(savedResult?.summary.contains("居住") == true, "最终摘要必须回答钱花哪了，包含 Top 分类居住")
        expect(savedResult?.summary.contains("数码") == true, "最终摘要必须回答钱花哪了，包含 Top 分类数码")
        expect(savedResult?.summary.contains("房租") == true || savedResult?.summary.contains("MacBook") == true,
               "最终摘要应包含可核对的大额样例")
        expect(savedResult?.summary.contains("无法获取对应") == false, "无证据的模型结论不能进入最终摘要")
        expect(savedResult?.summary.contains("finance.total.amount") == false, "最终摘要不能暴露内部 metricKey")
        expect(savedResult?.summary.contains("finance 工具返回") == false, "最终摘要不能暴露工具调用话术")
        expect((savedResult?.claims.count ?? 0) >= 3, "财务去向问题至少应形成总额、分类、样例三类观察")
    }

    /// 财务工具已经拿到事实时，LLM 最后一轮 JSON 格式失败不能让任务失败并把调试串展示给用户。
    private static func testRunLoop_财务工具已返回但模型JSON解析失败时用工具结果完成() async throws {
        let dir = makeTempDir()
        let brokenOutput = "模型说明：工具返回上月总支出 14598.83 元，但这里不是合法 JSON。"
        let client = FakeAgentLLMClient(responses: [brokenOutput, brokenOutput, brokenOutput])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()

        let job = try await fixture.runtime.startAnalysisJob(
            question: "上个月花了 1.4 万？钱都花哪儿去了？分析一下",
            now: now
        )
        let result = try await fixture.runtime.runLoop(
            jobID: job.id,
            systemTemplate: "你是 Agent",
            toolDescriptions: "【finance】消费工具",
            now: now
        )

        expect(result.state == .completed, "工具事实已返回时，解析失败应兜底完成而不是 failed，实际 \(result.state.rawValue)")
        expect(result.errorSummary == nil, "兜底完成不能留下解析失败调试串")

        let savedResult = await fixture.runtime.loadLatestResult()
        expect(savedResult?.summary.contains("14598.83") == true, "兜底结果应保留财务工具总额")
        expect(savedResult?.summary.contains("餐饮") == true, "兜底结果应保留分类去向")
        expect(savedResult?.summary.contains("房租") == true || savedResult?.summary.contains("MacBook") == true,
               "兜底结果应保留大额样例")
        expect(savedResult?.summary.contains("解析失败") == false, "用户结果不能出现 parser 调试串")
        expect(savedResult?.summary.contains("state=failed") == false, "用户结果不能出现 job 调试串")
    }

    /// 工具结果必须作为普通上下文进入下一轮 LLM，不能使用 OpenAI 原生 tool role。
    private static func testRunLoop_工具结果进入下一轮LLM上下文且不用原生tool角色() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"meal_spending","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()

        let job = try await fixture.runtime.startMockJob(question: "最近消费有什么变化", now: now)
        _ = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        let batches = await client.messageBatches
        expect(batches.count == 2, "应调用 LLM 两轮，实际 \(batches.count)")
        let secondBatch = batches[1]
        expect(!secondBatch.contains(where: { $0.role == .toolResult }), "第二轮 LLM 上下文不应包含原生 toolResult 角色")
        let joinedContent = secondBatch.map(\.content).joined(separator: "\n")
        expect(joinedContent.contains("finance.meal.nighttime_count"), "第二轮 LLM 上下文应包含工具 metric")
        expect(joinedContent.contains("晚餐消费"), "第二轮 LLM 上下文应包含工具事件摘要")
    }

    /// 工具事件进入 checkpoint/LLM 前应改写为全局唯一 evidence id，避免不同工具返回同名 event 时撞车。
    private static func testRunLoop_工具上下文使用全局唯一EvidenceID() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"meal_spending","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let finalClaims = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, finalClaims])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()

        let job = try await fixture.runtime.startMockJob(question: "最近消费有什么变化", now: now)
        _ = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        let expectedID = "\(job.id):finance:t-finance:event-1"
        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint?.evidenceRecordIDs == [expectedID],
               "checkpoint 应保存全局唯一 evidence id，实际 \(String(describing: checkpoint?.evidenceRecordIDs))")

        let batches = await client.messageBatches
        let joinedContent = batches[1].map(\.content).joined(separator: "\n")
        expect(joinedContent.contains(expectedID), "第二轮 LLM 上下文应暴露全局唯一 evidence id")
    }

    /// 模型一直不输出 final_claims 时，已有工具结果应兜底产出保守结论，避免用户看到预算耗尽。
    private static func testRunLoop_finalClaims必须经过Evidence校验() async throws {
        let dir = makeTempDir()
        let unsupportedClaim = #"{"status":"final_claims","reasoning":"证据足够","toolRequests":[],"claims":[{"id":"c1","type":"observation","displayText":"近两周消费从约 6630 元增至 9115 元","metricAssertions":[{"metricKey":"finance.amount.change","value":9115,"baselineValue":6630,"unit":"元","comparison":"increasing","evidenceIDs":["ghost"]}],"evidenceIDs":["ghost"],"prohibitedInferences":[],"confidence":0.9}],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [unsupportedClaim])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()

        let job = try await fixture.runtime.startMockJob(question: "分析最近消费", now: now)
        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        expect(result.state == .completed, "无证据 claim 不应让任务失败，应完成但过滤结论")
        let savedResult = await fixture.runtime.loadLatestResult()
        expect(savedResult?.claims.isEmpty == true, "无证据支撑的 claim 必须被过滤")
        expect(savedResult?.summary == "本期暂无显著观察", "过滤后应显示暂无显著观察")
    }

    /// 模型一直不输出 final_claims 时，已有工具结果应兜底产出保守结论，避免用户看到预算耗尽。
    private static func testRunLoop_模型不收敛时用工具结果兜底完成() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要查消费","toolRequests":[{"id":"t-finance","tool":"finance","query":"meal_spending","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let more = #"{"status":"need_more_analysis","reasoning":"还需要继续分析","toolRequests":[],"claims":[],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, more, more, more, more])
        let executor = FakeToolExecutor()
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: executor)
        let now = Date()

        let job = try await fixture.runtime.startMockJob(question: "最近消费有什么变化", now: now)
        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "【finance】消费工具",
            now: now.addingTimeInterval(1)
        )

        expect(result.state == .completed, "模型不收敛但已有工具结果时应兜底完成，实际 \(result.state.rawValue)")
        expect(result.errorSummary == nil, "兜底完成不应留下 errorSummary")

        let savedResult = await fixture.runtime.loadLatestResult()
        expect(savedResult?.claims.isEmpty == false, "兜底完成应保存至少 1 条 claim")
        expect(savedResult?.summary.contains("晚间餐饮频次偏移") == true, "兜底 summary 应来自 pattern signal")
    }

    private static func testRunLoop_动态查询结果经过证据校验后完成() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"需要现场计算","toolRequests":[{"id":"sleep-dynamic","tool":"health","query":"dynamic_query","dynamicPlan":{"source":"health.sleep","aggregations":[{"id":"average_sleep","operation":"average","field":"value","unit":"小时"}]}}],"claims":[],"warnings":[]}"#
        let invalidFinal = #"{"status":"final_claims","reasoning":"完成","toolRequests":[],"claims":[{"id":"bad","type":"observation","displayText":"平均睡眠 8 小时","metricAssertions":[{"metricKey":"dynamic.health_sleep.average_sleep.all","value":8,"unit":"小时","evidenceIDs":["ghost"]}],"evidenceIDs":["ghost"],"prohibitedInferences":[],"confidence":0.9}],"warnings":[]}"#
        let client = FakeAgentLLMClient(responses: [needTools, invalidFinal])
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: FakeToolExecutor())
        let now = Date()
        let job = try await fixture.runtime.startMockJob(question: "最近两周平均睡眠多久", now: now)
        let completed = try await fixture.runtime.runLoop(jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "动态健康目录", now: now.addingTimeInterval(1))
        let saved = await fixture.runtime.loadLatestResult()
        expect(completed.state == .completed, "动态查询应完成")
        expect(saved?.claims.first?.metricAssertions.first?.value == 7.2, "模型心算错误后必须回退到本地确定性结果")
        expect(saved?.summary.contains("7.2") == true, "最终摘要应来自动态计算结果")
    }

    private static func testRunLoop_睡眠质量降级仍输出完整可读结论() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"查询睡眠","toolRequests":[{"id":"sleep-summary","tool":"health","query":"sleep_summary","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let broken = "不是合法 JSON"
        let client = FakeAgentLLMClient(responses: [needTools, broken, broken])
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: FakeToolExecutor())
        let now = Date()
        let job = try await fixture.runtime.startMockJob(question: "最近的睡眠质量怎样？", now: now)
        _ = try await fixture.runtime.runLoop(jobID: job.id, systemTemplate: "Agent", toolDescriptions: "health", now: now)
        let saved = await fixture.runtime.loadLatestResult()
        let summary = saved?.summary ?? ""
        expect(summary.contains("平均睡眠 6.5 小时"), "应输出平均睡眠")
        expect(summary.contains("有效记录 7 晚"), "应输出有效记录")
        expect(summary.contains("低于 6 小时 2 晚"), "应输出低睡眠晚数")
        expect(summary.contains("相比上期减少 0.5 小时"), "应输出上期变化")
        expect(summary.contains("当前只能评估睡眠时长，不能完整判断睡眠质量"), "必须明确能力边界")
        expect(!summary.contains("health 数据返回"), "不能泄露工程兜底文案")
        expect(saved?.claims.first?.metricAssertions.count == 3, "健康 fallback 必须组合全部相关指标")
    }

    private static func testRunLoop_步数兜底输出完整可读结论与覆盖范围() async throws {
        let dir = makeTempDir()
        let needTools = #"{"status":"need_tools","reasoning":"查询步数","toolRequests":[{"id":"steps-summary","tool":"health","query":"steps_summary","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{}}],"claims":[],"warnings":[]}"#
        let broken = "不是合法 JSON"
        let client = FakeAgentLLMClient(responses: [needTools, broken, broken])
        let fixture = makeLoopRuntime(dir: dir, llmClient: client, toolExecutor: FakeToolExecutor())
        let now = Date()
        let job = try await fixture.runtime.startMockJob(question: "最近一个月平均步数是多少？", now: now)

        let completed = try await fixture.runtime.runLoop(
            jobID: job.id,
            systemTemplate: "Agent",
            toolDescriptions: "health",
            now: now
        )

        let saved = await fixture.runtime.loadLatestResult()
        let summary = saved?.summary ?? ""
        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(
            summary.contains("平均每天 6,991 步"),
            "步数 fallback 必须自然表达日均步数，state=\(completed.state.rawValue)，结果数=\(checkpoint?.completedToolResults.count ?? -1)，实际：\(summary)"
        )
        expect(summary.contains("达到 10,000 步 1 天"), "步数 fallback 必须完整补充达标天数")
        expect(!summary.contains("health."), "步数 fallback 不能暴露内部字段")
        expect(!summary.contains("建议"), "事实查询不能强行生成建议")
        expect(saved?.coverage?.coveredDays == 28, "结果必须保存有效记录天数")
        expect(saved?.coverage?.totalDays == 30, "结果必须保存查询总天数")
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
        let now = Date()
        let job = try await fixture.runtime.startMockJob(question: "q", now: now)

        try await fixture.runtime.pauseForBackground(now: now.addingTimeInterval(1))
        let resumed = try await fixture.runtime.resumeUnfinishedJobs(now: now.addingTimeInterval(2))
        expect(resumed == 1, "应恢复 1 个任务")

        let result = try await fixture.runtime.runLoop(
            jobID: job.id, systemTemplate: "你是 Agent", toolDescriptions: "tools",
            now: now.addingTimeInterval(3)
        )
        expect(result.state == .completed, "恢复后续跑应完成，实际 \(result.state.rawValue)")
    }
}
