//
//  HoloLocalAgentRuntime.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 1.5 Mock Agent Runtime
//  本地可恢复 Agent 执行骨架。Phase 1 不接 LLM / 不调真实 tool，
//  只用 mock 消息与 checkpoint 跑通「启动 → 推进 → 重启恢复 → 取消」生命周期。
//

import Foundation

actor HoloLocalAgentRuntime {

    private let persistence: HoloAgentPersistenceManager
    private let jobStore: HoloAgentJobStore
    private let checkpointStore: HoloAgentCheckpointStore
    private let patternMiner = HoloPatternMiner()
    private let llmClient: HoloAgentLLMClientProtocol?
    private let toolExecutor: HoloAgentToolExecuting?

    /// mock 阶段模拟的步骤序列：plan → executeTools → minePatterns → integrateResults → persistResult。
    private static let mockSequence: [HoloAgentStep] = [
        .plan, .executeTools, .minePatterns, .integrateResults, .persistResult
    ]

    /// 终态集合：resume 时遇到这些状态直接返回，不恢复执行。
    private static let terminalStates: Set<HoloAgentJobState> = [.completed, .failed, .cancelled]

    init(persistence: HoloAgentPersistenceManager,
         jobStore: HoloAgentJobStore,
         checkpointStore: HoloAgentCheckpointStore,
         llmClient: HoloAgentLLMClientProtocol? = nil,
         toolExecutor: HoloAgentToolExecuting? = nil) {
        self.persistence = persistence
        self.jobStore = jobStore
        self.checkpointStore = checkpointStore
        self.llmClient = llmClient
        self.toolExecutor = toolExecutor
    }

    /// 创建并启动一个 mock job：立即进入 running，写初始 checkpoint（step=plan）。
    func startMockJob(question: String, now: Date = Date()) async throws -> HoloAgentJob {
        var job = HoloAgentJob(
            id: UUID().uuidString, type: .debugMock, userQuestion: question,
            trigger: .debug, state: .running, currentStep: .plan,
            createdAt: now, updatedAt: now,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: now),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
        let checkpoint = Self.makeCheckpoint(
            jobID: job.id, step: .plan, completedSteps: [],
            conversation: [Self.mockUserMessage(question, now)], now: now
        )
        job.checkpointID = checkpoint.id
        // 写入顺序由 PersistenceManager 保证：evidence → checkpoint → job
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return job
    }

    /// 创建并启动一个真实深度分析 job（对话触发）：type=.deepAnalysis, trigger=.userQuestion。
    /// 写入初始 checkpoint（含用户问题），供 runLoop 多轮推进。生产路径用。
    func startAnalysisJob(question: String, sourceMessageID: UUID? = nil, now: Date = Date()) async throws -> HoloAgentJob {
        let resolvedTimeRange = Self.resolveQuestionTimeRange(question, referenceDate: now)
        var job = HoloAgentJob(
            id: UUID().uuidString, type: .deepAnalysis, userQuestion: question,
            trigger: .userQuestion, state: .running, currentStep: .plan,
            createdAt: now, updatedAt: now,
            lastForegroundRunAt: nil, timeRange: resolvedTimeRange,
            budget: HoloAgentBudget.normalDeep(now: now),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
        job.sourceMessageID = sourceMessageID
        let checkpoint = Self.makeCheckpoint(
            jobID: job.id, step: .plan, completedSteps: [],
            conversation: [Self.mockUserMessage(question, now)], now: now,
            inputSnapshotHash: Self.computeInputSnapshotHash(for: job)
        )
        job.checkpointID = checkpoint.id
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return job
    }

    /// 完成当前 step，推进到序列中的下一步并写新 checkpoint。
    /// 非运行态（已取消/已完成）不推进；序列走完后进入 completed。
    @discardableResult
    func completeCurrentStep(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        guard job.state == .running else { return job }

        let current = job.currentStep
        guard let index = Self.mockSequence.firstIndex(of: current) else {
            throw HoloAgentRuntimeError.unknownStep(current)
        }

        let latest = await checkpointStore.latestForJob(jobID: jobID)
        var completedSteps = latest?.completedSteps ?? []
        if !completedSteps.contains(current) { completedSteps.append(current) }

        // 完成工具执行后，在 minePatterns 步骤确定性挖掘趋势信号
        var patternSignals = latest?.patternSignals ?? []
        if current == .minePatterns {
            patternSignals = patternMiner.mine(toolResults: latest?.completedToolResults ?? [], now: now)
        }

        let isLast = index == Self.mockSequence.count - 1
        let nextStep = isLast ? current : Self.mockSequence[index + 1]

        let checkpoint = Self.makeCheckpoint(
            jobID: job.id, step: nextStep, completedSteps: completedSteps,
            conversation: latest?.conversationState ?? [],
            patternSignals: patternSignals, now: now
        )
        job.currentStep = nextStep
        job.checkpointID = checkpoint.id
        job.state = isLast ? .completed : .running
        job.updatedAt = now
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return job
    }

    /// 从最新 checkpoint 恢复（模拟 app 重启后继续）。
    /// 对齐 job.currentStep 与 checkpoint.step；终态任务不恢复。
    @discardableResult
    func resume(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        // 已结束的任务不复活
        guard !Self.terminalStates.contains(job.state) else { return job }

        guard let checkpoint = await checkpointStore.latestForJob(jobID: jobID) else {
            throw HoloAgentRuntimeError.checkpointMissing(jobID)
        }
        job.currentStep = checkpoint.step
        job.checkpointID = checkpoint.id
        if job.state != .running { job.state = .running }
        job.updatedAt = now
        try await jobStore.upsert(job)
        return job
    }

    /// 取消任务：状态置为 cancelled，不再继续执行。
    @discardableResult
    func cancel(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        job.state = .cancelled
        job.updatedAt = now
        try await jobStore.upsert(job)
        return job
    }

    // MARK: - 多轮 Agent Loop

    /// 汇总已注册工具的 Prompt 描述，供构建 agent_loop 系统提示。
    /// 未配置 toolExecutor 时返回空串（mock runtime 场景）。
    func toolDescriptions() async -> String {
        guard let toolExecutor else { return "" }
        return await toolExecutor.promptDescription()
    }

    /// 读取最近一条 Agent 结果，供记忆长廊展示（Phase 6.3）。
    func loadLatestResult() async -> HoloAgentResult? {
        await persistence.loadLatestResult()
    }

    /// 读取指定 IDs 的 evidence 记录，供结果渲染引用（Phase 6.3 evidence 引用）。
    func loadEvidence(forIDs ids: [String]) async -> [HoloEvidenceRecord] {
        await persistence.loadEvidence(forIDs: ids)
    }

    /// 读取指定 job 的 Agent 结果，供 Chat 恢复回填。
    func loadResult(jobID: String) async -> HoloAgentResult? {
        await persistence.loadResult(jobID: jobID)
    }

    /// 读取已到终态且带 Chat 来源消息的 job，供回前台后回填原 streaming 消息。
    func loadChatRecoverableTerminalJobs() async -> [HoloAgentJob] {
        let jobs = await jobStore.load()
        return jobs.filter { job in
            job.sourceMessageID != nil && Self.terminalStates.contains(job.state)
        }
    }

    /// 读取所有带 Chat 来源消息的 job，供 Chat 页面重建/回前台时同步真实进度。
    func loadChatLinkedJobs() async -> [HoloAgentJob] {
        let jobs = await jobStore.load()
        return jobs.filter { $0.sourceMessageID != nil }
    }

    /// 多轮 agent_loop：循环调用 LLM，按 status 推进，直到 final_claims 或轮数耗尽。
    /// 需要 llmClient 与 toolExecutor（未配置时抛 loopNotConfigured）。
    /// 注：循环条件含 wallTime 超时（§9.6）；Date() 不可注入但逻辑简单，测试靠 FakeLLM 同步快避免超时。
    func runLoop(jobID: String, systemTemplate: String, toolDescriptions: String,
                 now: Date = Date()) async throws -> HoloAgentJob {
        guard let llmClient, let toolExecutor else {
            throw HoloAgentRuntimeError.loopNotConfigured
        }
        guard var job = await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        guard !Self.terminalStates.contains(job.state) else { return job }
        if job.timeRange == nil,
           let question = job.userQuestion,
           let resolvedRange = Self.resolveQuestionTimeRange(question, referenceDate: now) {
            job.timeRange = resolvedRange
        }

        var checkpoint = await checkpointStore.latestForJob(jobID: jobID)
            ?? Self.makeCheckpoint(jobID: jobID, step: .plan, completedSteps: [],
                                   conversation: [], now: now)
        try await executeDeterministicPrerequisiteToolsIfNeeded(
            job: &job,
            checkpoint: &checkpoint,
            now: now
        )
        var retryCount = 0
        let maxRetries = 2

        while job.budget.consumedLLMRounds < job.budget.maxLLMRounds,
              Date().timeIntervalSince(job.budget.startedAt) < TimeInterval(job.budget.maxWallTimeSeconds) {
            try Task.checkCancellation()
            job.state = .waitingForLLM
            job.updatedAt = now

            var conversationState = checkpoint.conversationState
            if job.budget.maxLLMRounds - job.budget.consumedLLMRounds == 1 {
                conversationState.append(Self.finalRoundInstruction(now: now))
            }

            let messages = HoloAgentPromptBuilder.build(
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions,
                evidence: [],
                conversationState: conversationState,
                userQuestion: job.userQuestion ?? ""
            )
            let raw = try await llmClient.next(messages: messages)
            job.budget.consumedLLMRounds += 1

            let output: HoloAgentOutput
            do {
                output = try HoloAgentResponseParser.parse(raw, remainingRetries: maxRetries - retryCount)
            } catch HoloAgentError.outputParseFailure(let needsRetry) {
                if needsRetry {
                    retryCount += 1
                    job.state = .retrying
                    continue
                }
                let fallbackClaims = Self.fallbackClaims(
                    toolResults: checkpoint.completedToolResults,
                    patternSignals: checkpoint.patternSignals
                )
                if !fallbackClaims.isEmpty {
                    checkpoint.conversationState.append(Self.fallbackAssistantMessage(claims: fallbackClaims, now: now))
                    checkpoint.step = .verifyClaims
                    return try await completeWithClaims(fallbackClaims, job: &job, checkpoint: checkpoint, now: now)
                }
                job.state = .failed
                job.errorSummary = "解析失败重试耗尽。len=\(raw.count) 前200=\(String(raw.prefix(200))) 尾100=\(String(raw.suffix(100)))"
                job.updatedAt = now
                try await jobStore.upsert(job)
                return job
            }

            checkpoint.conversationState.append(Self.assistantMessage(for: output, now: now))

            switch output.status {
            case .needTools:
                if !output.toolRequests.isEmpty {
                    job.budget.consumedToolBatches += 1
                }
                for request in output.toolRequests {
                    if Self.hasCompletedEquivalentToolRequest(request, in: checkpoint.completedToolResults) {
                        continue
                    }
                    let scopedRequest = Self.requestWithJobScope(request, job: job)
                    let rawResult = await toolExecutor.execute(scopedRequest)
                    let result = Self.resultWithCanonicalEvidenceIDs(rawResult, jobID: job.id)
                    checkpoint.completedToolResults.append(result)
                    let evidence = Self.evidenceRecords(
                        from: result,
                        request: scopedRequest,
                        jobID: job.id,
                        now: now
                    )
                    checkpoint.evidenceRecordIDs.append(contentsOf: evidence.map(\.id))
                    try await persistence.saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)
                }
                checkpoint.patternSignals.append(
                    contentsOf: patternMiner.mine(toolResults: checkpoint.completedToolResults, now: now)
                )
                checkpoint.conversationState.append(Self.toolResultMessage(
                    toolResults: checkpoint.completedToolResults,
                    patternSignals: checkpoint.patternSignals,
                    now: now
                ))
                checkpoint.step = .executeTools
                try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
            case .needMoreAnalysis:
                checkpoint.step = .continueOrConclude
                try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
            case .finalClaims:
                checkpoint.step = .verifyClaims
                return try await completeWithClaims(output.claims, job: &job, checkpoint: checkpoint, now: now)
            }
        }

        let fallbackClaims = Self.fallbackClaims(
            toolResults: checkpoint.completedToolResults,
            patternSignals: checkpoint.patternSignals
        )
        if !fallbackClaims.isEmpty {
            checkpoint.conversationState.append(Self.fallbackAssistantMessage(claims: fallbackClaims, now: now))
            checkpoint.step = .verifyClaims
            return try await completeWithClaims(fallbackClaims, job: &job, checkpoint: checkpoint, now: now)
        }

        job.state = .failed
        job.errorSummary = "Agent 预算耗尽（LLM 轮数上限）"
        job.updatedAt = now
        try await jobStore.upsert(job)
        return job
    }

    // MARK: - 后台/前台生命周期

    /// 进入后台：把运行中任务标记为 waitingForForeground，便于前台恢复。
    func pauseForBackground(now: Date = Date()) async throws {
        let jobs = await jobStore.load()
        for var job in jobs where job.state == .running
            || job.state == .waitingForLLM
            || job.state == .retrying {
            job.state = .waitingForForeground
            job.lastForegroundRunAt = now
            job.updatedAt = now
            try await jobStore.upsert(job)
        }
    }

    /// 回到前台：恢复所有未结束（非终态、非 running）的任务，返回恢复数量。
    /// 注：本方法仅标记状态、不重启推理；真正闭合恢复链由 HoloAgentScheduler.resumeAndContinue 负责。
    @discardableResult
    func resumeUnfinishedJobs(now: Date = Date()) async throws -> Int {
        let jobs = await jobStore.load()
        var resumed = 0
        for job in jobs
            where !Self.terminalStates.contains(job.state) && job.state != .running {
            _ = try? await resume(jobID: job.id, now: now)
            resumed += 1
        }
        return resumed
    }

    /// 收集所有非终态 job 的 ID（含 running 孤儿与 waitingForForeground），供 Scheduler 拉起 runLoop。
    /// 与 resumeUnfinishedJobs 的区别：不排除 running（进程被硬杀的孤儿落盘仍是 running）、不修改状态——
    /// 是否真正重启推理由 Scheduler 决定，本方法只负责给出「需要被推进」的 job 清单。
    func collectResumableJobIDs(now: Date = Date()) async -> [String] {
        let jobs = await jobStore.load()
        return jobs.filter { !Self.terminalStates.contains($0.state) }.map(\.id)
    }

    /// 收集所有非终态 job（含 running 孤儿），供 Scheduler 排序、限量、拉起 runLoop。
    func collectResumableJobs(now: Date = Date()) async -> [HoloAgentJob] {
        let jobs = await jobStore.load()
        return jobs.filter { !Self.terminalStates.contains($0.state) }
    }

    /// 返回某 job 的最新 checkpoint，供 Scheduler 恢复前校验 inputSnapshotHash。
    func latestCheckpointForJob(jobID: String) async -> HoloAgentCheckpoint? {
        await checkpointStore.latestForJob(jobID: jobID)
    }

    /// 清理终态且超保留期的 job 及其关联 checkpoint/result（透传 persistence，§9.6 体积治理）。
    @discardableResult
    func cleanupTerminalJobs(policy: HoloJobCleanupPolicy, now: Date = Date()) async throws -> [String] {
        try await persistence.cleanupTerminalJobs(policy: policy, now: now)
    }

    // MARK: - 内部辅助

    private func loadJob(_ jobID: String) async -> HoloAgentJob? {
        await jobStore.load().first { $0.id == jobID }
    }

    private static func makeCheckpoint(
        jobID: String, step: HoloAgentStep, completedSteps: [HoloAgentStep],
        conversation: [HoloAgentMessage], patternSignals: [HoloPatternSignal] = [],
        now: Date,
        inputSnapshotHash: String? = nil
    ) -> HoloAgentCheckpoint {
        HoloAgentCheckpoint(
            id: UUID().uuidString, jobID: jobID, step: step, completedSteps: completedSteps,
            conversationState: conversation, pendingToolRequests: [], completedToolResults: [],
            patternSignals: patternSignals, evidenceRecordIDs: [], validatedClaimIDs: [],
            memoryCandidateIDs: [], retryCountByStep: [:],
            createdAt: now, updatedAt: now,
            schemaVersion: inputSnapshotHash == nil ? nil : 1,
            inputSnapshotHash: inputSnapshotHash
        )
    }

    /// 基于 job 输入计算稳定 hash（userQuestion + timeRange），用于恢复时对比。
    private static func computeInputSnapshotHash(for job: HoloAgentJob) -> String {
        var hasher = Hasher()
        hasher.combine(job.userQuestion)
        if let start = job.timeRange?.start { hasher.combine(start) }
        if let end = job.timeRange?.end { hasher.combine(end) }
        return String(hasher.finalize())
    }

    private static func resolveQuestionTimeRange(_ question: String, referenceDate: Date) -> HoloAgentTimeRange? {
        HoloAgentTimeSemanticResolver.resolve(question, referenceDate: referenceDate)?.timeRange
    }

    private static func requestWithJobScope(_ request: HoloToolRequest, job: HoloAgentJob) -> HoloToolRequest {
        guard request.timeRange == nil, let jobRange = job.timeRange else {
            return request
        }
        var scoped = request
        scoped.timeRange = jobRange
        return scoped
    }

    private static func hasCompletedEquivalentToolRequest(_ request: HoloToolRequest, in results: [HoloDataToolResult]) -> Bool {
        results.contains { result in
            result.tool == request.tool &&
            result.toolRequestID.contains(request.query) &&
            (result.status == .success || result.status == .partial || result.status == .empty)
        }
    }

    private func executeDeterministicPrerequisiteToolsIfNeeded(
        job: inout HoloAgentJob,
        checkpoint: inout HoloAgentCheckpoint,
        now: Date
    ) async throws {
        guard let toolExecutor,
              let question = job.userQuestion else { return }

        let plannedRequests = Self.deterministicToolRequests(for: question)
        guard !plannedRequests.isEmpty else { return }

        let completedKeys = Set(checkpoint.completedToolResults.map { "\($0.tool):\($0.toolRequestID)" })
        var executedAny = false

        for request in plannedRequests {
            guard !completedKeys.contains("\(request.tool):\(request.id)") else { continue }
            let scopedRequest = Self.requestWithJobScope(request, job: job)
            let rawResult = await toolExecutor.execute(scopedRequest)
            let result = Self.resultWithCanonicalEvidenceIDs(rawResult, jobID: job.id)
            checkpoint.completedToolResults.append(result)
            let evidence = Self.evidenceRecords(
                from: result,
                request: scopedRequest,
                jobID: job.id,
                now: now
            )
            checkpoint.evidenceRecordIDs.append(contentsOf: evidence.map(\.id))
            try await persistence.saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)
            executedAny = true
        }

        guard executedAny else { return }
        checkpoint.patternSignals.append(
            contentsOf: patternMiner.mine(toolResults: checkpoint.completedToolResults, now: now)
        )
        checkpoint.conversationState.append(Self.toolResultMessage(
            toolResults: checkpoint.completedToolResults,
            patternSignals: checkpoint.patternSignals,
            now: now
        ))
        checkpoint.step = .executeTools
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
    }

    private static func deterministicToolRequests(for question: String) -> [HoloToolRequest] {
        let normalized = question.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        let asksSpendingDestination =
            normalized.contains("钱都花哪") ||
            normalized.contains("钱花哪") ||
            normalized.contains("花哪儿") ||
            normalized.contains("花哪里") ||
            normalized.contains("去哪了") ||
            normalized.contains("去哪里了") ||
            normalized.contains("消费结构") ||
            normalized.contains("支出结构")
        let mentionsAmountAnchor =
            normalized.contains("1.4万") ||
            normalized.contains("14000") ||
            normalized.contains("一万四")

        guard asksSpendingDestination || (mentionsAmountAnchor && normalized.contains("花")) else {
            return []
        }

        return [
            HoloToolRequest(
                id: "deterministic-finance-spending_breakdown",
                tool: "finance",
                query: "spending_breakdown",
                timeRange: nil,
                baseline: nil,
                requiredMetrics: ["finance.total.amount", "finance.category.amount", "finance.transaction.sample"],
                parameters: [:]
            )
        ]
    }

    private static func mockUserMessage(_ content: String, _ now: Date) -> HoloAgentMessage {
        HoloAgentMessage(role: .user, content: content, toolRequestID: nil, toolName: nil,
                         timestamp: now, tokenEstimate: nil)
    }

    private static func assistantMessage(for output: HoloAgentOutput, now: Date) -> HoloAgentMessage {
        HoloAgentMessage(role: .assistant, content: output.reasoning, toolRequestID: nil, toolName: nil,
                         timestamp: now, tokenEstimate: nil)
    }

    private static func finalRoundInstruction(now: Date) -> HoloAgentMessage {
        HoloAgentMessage(
            role: .system,
            content: "这是本次 Agent Loop 的最后一轮。必须基于已有工具结果输出 final_claims；不要再输出 need_tools 或 need_more_analysis。若证据有限，请给出低置信、带边界的观察。",
            toolRequestID: nil,
            toolName: nil,
            timestamp: now,
            tokenEstimate: nil
        )
    }

    private static func fallbackAssistantMessage(claims: [HoloAgentClaim], now: Date) -> HoloAgentMessage {
        let summary = claims.map(\.displayText).joined(separator: "；")
        return HoloAgentMessage(
            role: .assistant,
            content: "模型未在预算内收敛，本地基于工具结果生成保守结论：\(summary)",
            toolRequestID: nil,
            toolName: nil,
            timestamp: now,
            tokenEstimate: nil
        )
    }

    private static func toolResultMessage(
        toolResults: [HoloDataToolResult],
        patternSignals: [HoloPatternSignal],
        now: Date
    ) -> HoloAgentMessage {
        let payload = HoloAgentToolContextPayload(
            toolResults: toolResults,
            patternSignals: patternSignals
        )
        let content = """
        工具执行结果（作为上下文使用，不是原生 tool call）：
        \(Self.encodeToolContext(payload))
        """
        return HoloAgentMessage(role: .assistant, content: content, toolRequestID: nil, toolName: nil,
                                timestamp: now, tokenEstimate: nil)
    }

    private static func encodeToolContext(_ payload: HoloAgentToolContextPayload) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"toolResults":[],"patternSignals":[]}"#
        }
        return string
    }

    private func completeWithClaims(
        _ claims: [HoloAgentClaim],
        job: inout HoloAgentJob,
        checkpoint: HoloAgentCheckpoint,
        now: Date
    ) async throws -> HoloAgentJob {
        let availableEvidenceIDs = Array(Set(checkpoint.evidenceRecordIDs + claims.flatMap(\.evidenceIDs)))
        let evidence = await persistence.loadEvidence(forIDs: availableEvidenceIDs)
        let verification = HoloClaimVerifier().verify(claims: claims, evidence: evidence)
        var acceptedClaims = verification.acceptedClaims
        if acceptedClaims.isEmpty {
            let fallback = Self.fallbackClaims(
                toolResults: checkpoint.completedToolResults,
                patternSignals: checkpoint.patternSignals
            )
            if !fallback.isEmpty {
                let fallbackEvidenceIDs = Array(Set(checkpoint.evidenceRecordIDs + fallback.flatMap(\.evidenceIDs)))
                let fallbackEvidence = await persistence.loadEvidence(forIDs: fallbackEvidenceIDs)
                acceptedClaims = HoloClaimVerifier()
                    .verify(claims: fallback, evidence: fallbackEvidence)
                    .acceptedClaims
            }
        }
        let resultEvidenceIDs = Array(Set(acceptedClaims.flatMap(\.evidenceIDs)))
        let agentResult = HoloAgentResult(
            id: UUID().uuidString,
            jobID: job.id,
            title: "深度分析",
            summary: acceptedClaims.isEmpty
                ? "本期暂无显著观察"
                : acceptedClaims.map(\.displayText).joined(separator: "；"),
            claims: acceptedClaims,
            evidenceIDs: resultEvidenceIDs,
            memoryCandidateIDs: [],
            status: "completed",
            generatedAt: now,
            updatedAt: now
        )
        try await persistence.saveResult(agentResult)
        job.resultID = agentResult.id
        job.state = .completed
        job.errorSummary = nil
        job.updatedAt = now
        try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return job
    }

    private static func evidenceRecords(
        from result: HoloDataToolResult,
        request: HoloToolRequest,
        jobID: String,
        now: Date
    ) -> [HoloEvidenceRecord] {
        result.events.compactMap { event in
            guard let metricKey = event.metricKey else { return nil }
            return HoloEvidenceRecord(
                id: event.id,
                dedupeKey: "\(jobID):\(result.tool):\(event.id)",
                sourceModule: HoloAgentEvidencePolicy.sourceModule(for: result.tool),
                sourceID: event.id,
                sourceKind: request.query,
                timeRange: event.timeRange ?? request.timeRange,
                occurredAt: event.occurredAt,
                metricKey: metricKey,
                metricValue: event.metricValue,
                unit: result.metrics.first { $0.metricKey == metricKey }?.unit,
                baselineValue: result.metrics.first { $0.metricKey == metricKey }?.baselineValue,
                baselineTimeRange: event.baselineTimeRange ?? request.baseline,
                comparison: result.metrics.first { $0.metricKey == metricKey }?.comparison,
                excerpt: event.excerpt,
                redactedExcerpt: event.excerpt,
                sensitivity: HoloAgentEvidencePolicy.sensitivity(for: result),
                confidence: result.status == .success ? 0.9 : 0.5,
                status: result.status == .success ? .active : .partial,
                generatedBy: "holo_agent_tool",
                generatedAt: now,
                referencedByJobIDs: [jobID],
                referencedByMemoryIDs: [],
                deviceID: nil
            )
        }
    }

    private static func resultWithCanonicalEvidenceIDs(_ result: HoloDataToolResult,
                                                       jobID: String) -> HoloDataToolResult {
        var updated = result
        updated.events = result.events.map { event in
            var updatedEvent = event
            updatedEvent.id = evidenceRecordID(
                jobID: jobID,
                tool: result.tool,
                toolRequestID: result.toolRequestID,
                eventID: event.id
            )
            return updatedEvent
        }
        return updated
    }

    private static func evidenceRecordID(jobID: String, tool: String, toolRequestID: String, eventID: String) -> String {
        "\(jobID):\(tool):\(toolRequestID):\(eventID)"
    }

    private static func fallbackClaims(
        toolResults: [HoloDataToolResult],
        patternSignals: [HoloPatternSignal]
    ) -> [HoloAgentClaim] {
        if !patternSignals.isEmpty {
            return patternSignals.prefix(3).map { signal in
                HoloAgentClaim(
                    id: "fallback-\(signal.id)",
                    type: "observation",
                    displayText: "\(signal.title)：\(signal.reason)",
                    metricAssertions: [
                        HoloMetricAssertion(
                            metricKey: signal.metricKey,
                            value: signal.value,
                            baselineValue: signal.baselineValue,
                            unit: nil,
                            comparison: nil,
                            evidenceIDs: signal.evidenceIDs
                        )
                    ],
                    evidenceIDs: signal.evidenceIDs,
                    prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                    confidence: 0.45
                )
            }
        }

        return toolResults.prefix(3).flatMap { result -> [HoloAgentClaim] in
            guard result.status == .success || result.status == .partial || result.status == .empty else {
                return []
            }
            if result.tool == "finance", result.toolRequestID.contains("spending_breakdown") {
                let claims = financeSpendingBreakdownFallbackClaims(from: result)
                if !claims.isEmpty { return claims }
            }
            let metric = result.metrics.first
            let event = result.events.first
            let evidenceIDsForMetric = metric.map { metric in
                result.events
                    .filter { $0.metricKey == metric.metricKey }
                    .map(\.id)
            } ?? []
            let text: String
            if let metric {
                text = Self.fallbackDisplayText(for: result, metric: metric, event: event)
            } else if let event {
                text = event.excerpt
            } else {
                text = "\(result.tool) 工具已返回数据，但没有显著趋势"
            }
            return [HoloAgentClaim(
                id: "fallback-\(result.toolRequestID)",
                type: "observation",
                displayText: text,
                metricAssertions: metric.map {
                    [
                        HoloMetricAssertion(
                            metricKey: $0.metricKey,
                            value: $0.value,
                            baselineValue: $0.baselineValue,
                            unit: $0.unit,
                            comparison: $0.comparison,
                            evidenceIDs: evidenceIDsForMetric
                        )
                    ]
                } ?? [],
                evidenceIDs: metric == nil ? result.events.map(\.id) : evidenceIDsForMetric,
                prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                confidence: result.status == .empty ? 0.3 : 0.45
            )]
        }
    }

    private static func financeSpendingBreakdownFallbackClaims(from result: HoloDataToolResult) -> [HoloAgentClaim] {
        let totalMetric = result.metrics.first { $0.metricKey == "finance.total.amount" }
        let totalEvidence = result.events.first { $0.metricKey == "finance.total.amount" }
        let categoryMetrics = result.metrics
            .filter { $0.metricKey == "finance.category.amount" && ($0.value ?? 0) > 0 }
            .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
            .prefix(3)
        let sampleEvents = result.events
            .filter { $0.metricKey == "finance.transaction.sample" }
            .prefix(3)
        let rangeLabel = totalEvidence?.timeRange?.label
            ?? result.events.compactMap { $0.timeRange?.label }.first
            ?? "本期"

        var claims: [HoloAgentClaim] = []

        if let totalMetric, let totalEvidence {
            let totalText = totalMetric.value.map(moneyText) ?? "已有记录"
            claims.append(
                HoloAgentClaim(
                    id: "fallback-\(result.toolRequestID)-total",
                    type: "observation",
                    displayText: "\(rangeLabel)账单总支出约 \(totalText) 元。",
                    metricAssertions: [
                        HoloMetricAssertion(
                            metricKey: "finance.total.amount",
                            value: totalMetric.value,
                            baselineValue: totalMetric.baselineValue,
                            unit: totalMetric.unit,
                            comparison: totalMetric.comparison,
                            evidenceIDs: [totalEvidence.id]
                        )
                    ],
                    evidenceIDs: [totalEvidence.id],
                    prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                    confidence: 0.55
                )
            )
        }

        let categoryAssertions: [HoloMetricAssertion] = categoryMetrics.compactMap { metric in
            guard let evidence = matchingEvidence(for: metric, in: result.events) else { return nil }
            return HoloMetricAssertion(
                metricKey: metric.metricKey,
                value: metric.value,
                baselineValue: metric.baselineValue,
                unit: metric.unit,
                comparison: metric.comparison,
                evidenceIDs: [evidence.id]
            )
        }
        let categoryEvidenceIDs = categoryAssertions.flatMap(\.evidenceIDs)
        let categoryText = categoryMetrics
            .compactMap { metric -> String? in
                guard let category = metric.comparison, let value = metric.value else { return nil }
                return "\(category) \(moneyText(value)) 元"
            }
            .joined(separator: "、")
        if !categoryAssertions.isEmpty, !categoryText.isEmpty {
            claims.append(
                HoloAgentClaim(
                    id: "fallback-\(result.toolRequestID)-categories",
                    type: "observation",
                    displayText: "\(rangeLabel)主要去向是 \(categoryText)，这些是优先核对的分类。",
                    metricAssertions: categoryAssertions,
                    evidenceIDs: categoryEvidenceIDs,
                    prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                    confidence: 0.55
                )
            )
        }

        let sampleEvidenceIDs = sampleEvents.map(\.id)
        let sampleText = sampleEvents
            .map { cleanupFinanceSampleExcerpt($0.excerpt, rangeLabel: rangeLabel) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
        if !sampleEvidenceIDs.isEmpty, !sampleText.isEmpty {
            claims.append(
                HoloAgentClaim(
                    id: "fallback-\(result.toolRequestID)-samples",
                    type: "observation",
                    displayText: "\(rangeLabel)最大几笔包括：\(sampleText)。",
                    metricAssertions: [
                        HoloMetricAssertion(
                            metricKey: "finance.transaction.sample",
                            value: nil,
                            baselineValue: nil,
                            unit: nil,
                            comparison: nil,
                            evidenceIDs: sampleEvidenceIDs
                        )
                    ],
                    evidenceIDs: sampleEvidenceIDs,
                    prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                    confidence: 0.5
                )
            )
        }

        return claims
    }

    private static func matchingEvidence(for metric: HoloMetric, in events: [HoloEvidenceEvent]) -> HoloEvidenceEvent? {
        events.first { event in
            guard event.metricKey == metric.metricKey else { return false }
            if let value = metric.value, let eventValue = event.metricValue {
                return value == eventValue
            }
            return true
        }
    }

    private static func cleanupFinanceSampleExcerpt(_ excerpt: String, rangeLabel: String) -> String {
        excerpt
            .replacingOccurrences(of: "\(rangeLabel)大额支出样例：", with: "")
            .replacingOccurrences(of: "本期大额支出样例：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackDisplayText(
        for result: HoloDataToolResult,
        metric: HoloMetric,
        event: HoloEvidenceEvent?
    ) -> String {
        if result.tool == "finance" {
            let rangeLabel = event?.timeRange?.label ?? "本期"
            let valueText = metric.value.map { moneyText($0) } ?? "已有记录"
            switch metric.metricKey {
            case "finance.total.amount":
                return "\(rangeLabel)账单总支出约 \(valueText) 元，先按账单口径核对主要去向。"
            case "finance.category.amount":
                let category = metric.comparison?.isEmpty == false ? metric.comparison! : "该分类"
                return "\(rangeLabel)\(category)支出约 \(valueText) 元，是账单里值得优先核对的一项。"
            case "finance.amount.change":
                return "\(rangeLabel)消费金额变化约 \(valueText) 元，可作为本轮分析的账单观察。"
            case "finance.keyword.amount":
                return "\(rangeLabel)相关消费约 \(valueText) 元，可继续从账单明细核对。"
            default:
                return event?.excerpt ?? "\(rangeLabel)账单已有可核对记录。"
            }
        }

        let valueText = metric.value.map { String(format: "%.0f", $0) } ?? "已有记录"
        return "\(result.tool) 数据返回一项可核对观察：\(valueText)"
    }

    private static func moneyText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

private struct HoloAgentToolContextPayload: Codable {
    var toolResults: [HoloDataToolResult]
    var patternSignals: [HoloPatternSignal]
}

/// Runtime 错误：用中文描述，便于上层展示与日志。
enum HoloAgentRuntimeError: Error, LocalizedError {
    case jobNotFound(String)
    case checkpointMissing(String)
    case unknownStep(HoloAgentStep)
    case loopNotConfigured

    var errorDescription: String? {
        switch self {
        case .jobNotFound(let id): return "找不到 Agent 任务：\(id)"
        case .checkpointMissing(let id): return "找不到任务的可恢复快照：\(id)"
        case .unknownStep(let step): return "mock 序列未覆盖步骤：\(step.rawValue)"
        case .loopNotConfigured: return "Agent Loop 未配置 LLM client 或 tool executor"
        }
    }
}
