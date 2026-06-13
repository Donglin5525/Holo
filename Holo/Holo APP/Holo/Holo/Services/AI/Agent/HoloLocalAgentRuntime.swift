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
    func startAnalysisJob(question: String, now: Date = Date()) async throws -> HoloAgentJob {
        var job = HoloAgentJob(
            id: UUID().uuidString, type: .deepAnalysis, userQuestion: question,
            trigger: .userQuestion, state: .running, currentStep: .plan,
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

    /// 多轮 agent_loop：循环调用 LLM，按 status 推进，直到 final_claims 或轮数耗尽。
    /// 需要 llmClient 与 toolExecutor（未配置时抛 loopNotConfigured）。
    /// 注：循环条件用 LLM 轮数，不依赖 budget.isExhausted 的 wallTime（其内部用 Date() 无法注入测试时间）。
    func runLoop(jobID: String, systemTemplate: String, toolDescriptions: String,
                 now: Date = Date()) async throws -> HoloAgentJob {
        guard let llmClient, let toolExecutor else {
            throw HoloAgentRuntimeError.loopNotConfigured
        }
        guard var job = await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        guard !Self.terminalStates.contains(job.state) else { return job }

        var checkpoint = await checkpointStore.latestForJob(jobID: jobID)
            ?? Self.makeCheckpoint(jobID: jobID, step: .plan, completedSteps: [],
                                   conversation: [], now: now)
        var retryCount = 0
        let maxRetries = 2

        while job.budget.consumedLLMRounds < job.budget.maxLLMRounds {
            try Task.checkCancellation()
            job.state = .waitingForLLM
            job.updatedAt = now

            let messages = HoloAgentPromptBuilder.build(
                systemTemplate: systemTemplate,
                toolDescriptions: toolDescriptions,
                evidence: [],
                conversationState: checkpoint.conversationState,
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
                job.state = .failed
                job.errorSummary = "解析失败重试耗尽。len=\(raw.count) 前200=\(String(raw.prefix(200))) 尾100=\(String(raw.suffix(100)))"
                job.updatedAt = now
                try await jobStore.upsert(job)
                return job
            }

            checkpoint.conversationState.append(Self.assistantMessage(for: output, now: now))

            switch output.status {
            case .needTools:
                for request in output.toolRequests {
                    let result = await toolExecutor.execute(request)
                    checkpoint.completedToolResults.append(result)
                }
                checkpoint.patternSignals.append(
                    contentsOf: patternMiner.mine(toolResults: checkpoint.completedToolResults, now: now)
                )
                checkpoint.conversationState.append(Self.toolResultMessage(for: output, now: now))
                checkpoint.step = .executeTools
                try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
            case .needMoreAnalysis:
                checkpoint.step = .continueOrConclude
                try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
            case .finalClaims:
                checkpoint.step = .verifyClaims
                // 构造最终结果（claims + 汇总 evidenceIDs）并持久化，供记忆长廊展示
                let resultEvidenceIDs = Array(Set(output.claims.flatMap(\.evidenceIDs)))
                let agentResult = HoloAgentResult(
                    id: UUID().uuidString,
                    jobID: job.id,
                    title: "深度分析",
                    summary: output.claims.isEmpty
                        ? "本期暂无显著观察"
                        : output.claims.map(\.displayText).joined(separator: "；"),
                    claims: output.claims,
                    evidenceIDs: resultEvidenceIDs,
                    memoryCandidateIDs: [],
                    status: "completed",
                    generatedAt: now,
                    updatedAt: now
                )
                try await persistence.saveResult(agentResult)
                job.resultID = agentResult.id
                job.state = .completed
                job.updatedAt = now
                try await persistence.saveProgress(job: job, evidence: [], checkpoint: checkpoint)
                return job
            }
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

    // MARK: - 内部辅助

    private func loadJob(_ jobID: String) async -> HoloAgentJob? {
        await jobStore.load().first { $0.id == jobID }
    }

    private static func makeCheckpoint(
        jobID: String, step: HoloAgentStep, completedSteps: [HoloAgentStep],
        conversation: [HoloAgentMessage], patternSignals: [HoloPatternSignal] = [],
        now: Date
    ) -> HoloAgentCheckpoint {
        HoloAgentCheckpoint(
            id: UUID().uuidString, jobID: jobID, step: step, completedSteps: completedSteps,
            conversationState: conversation, pendingToolRequests: [], completedToolResults: [],
            patternSignals: patternSignals, evidenceRecordIDs: [], validatedClaimIDs: [],
            memoryCandidateIDs: [], retryCountByStep: [:],
            createdAt: now, updatedAt: now
        )
    }

    private static func mockUserMessage(_ content: String, _ now: Date) -> HoloAgentMessage {
        HoloAgentMessage(role: .user, content: content, toolRequestID: nil, toolName: nil,
                         timestamp: now, tokenEstimate: nil)
    }

    private static func assistantMessage(for output: HoloAgentOutput, now: Date) -> HoloAgentMessage {
        HoloAgentMessage(role: .assistant, content: output.reasoning, toolRequestID: nil, toolName: nil,
                         timestamp: now, tokenEstimate: nil)
    }

    private static func toolResultMessage(for output: HoloAgentOutput, now: Date) -> HoloAgentMessage {
        let toolNames = output.toolRequests.map(\.tool).joined(separator: ",")
        let content = output.toolRequests.isEmpty ? "无工具请求" : "已执行工具：\(toolNames)"
        return HoloAgentMessage(role: .toolResult, content: content, toolRequestID: nil, toolName: nil,
                                timestamp: now, tokenEstimate: nil)
    }
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
