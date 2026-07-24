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

    /// 模块内可访问：HoloBackgroundContinuationManager 装配 ConsistencyReconciler 时需要（§5.4）。
    let persistence: HoloAgentPersistenceManager
    /// 模块内可访问：HoloAgentScheduler 需要 generation CAS 与并发门控读 job（§6.1）。
    let jobStore: HoloAgentJobStore
    private let checkpointStore: HoloAgentCheckpointStore
    private let patternMiner = HoloPatternMiner()
    private let llmClient: HoloAgentLLMClientProtocol?
    private let toolExecutor: HoloAgentToolExecuting?
    private let memoryQueryService: HoloMemoryQueryService?
    private let eventRecorder: any HoloAgentEventRecording

    /// mock 阶段模拟的步骤序列：plan → executeTools → minePatterns → integrateResults → persistResult。
    private static let mockSequence: [HoloAgentStep] = [
        .plan, .executeTools, .minePatterns, .integrateResults, .persistResult
    ]

    /// 终态集合：resume 时遇到这些状态直接返回，不恢复执行。
    private static let terminalStates: Set<HoloAgentJobState> = [.completed, .failed, .cancelled, .superseded]

    init(persistence: HoloAgentPersistenceManager,
         jobStore: HoloAgentJobStore,
         checkpointStore: HoloAgentCheckpointStore,
         llmClient: HoloAgentLLMClientProtocol? = nil,
         toolExecutor: HoloAgentToolExecuting? = nil,
         memoryQueryService: HoloMemoryQueryService? = nil,
         eventRecorder: any HoloAgentEventRecording = HoloNoopAgentEventRecorder.shared) {
        self.persistence = persistence
        self.jobStore = jobStore
        self.checkpointStore = checkpointStore
        self.llmClient = llmClient
        self.toolExecutor = toolExecutor
        self.memoryQueryService = memoryQueryService
        self.eventRecorder = eventRecorder
    }

    /// 创建并启动一个 mock job：立即进入 running，写初始 checkpoint（step=plan）。
    func startMockJob(question: String, now: Date = Date()) async throws -> HoloAgentJob {
        var job = HoloAgentJob(
            id: UUID().uuidString, type: .debugMock, userQuestion: question,
            trigger: .debug, state: .running, currentStep: .plan,
            createdAt: now, updatedAt: now,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: now),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil,
            referenceDate: now, snapshotCutoffAt: now,
            absoluteDeadline: now.addingTimeInterval(HoloAgentJob.absoluteDeadlineInterval)
        )
        let checkpoint = Self.makeCheckpoint(
            jobID: job.id, step: .plan, completedSteps: [],
            conversation: [Self.mockUserMessage(question, now)], now: now
        )
        job.checkpointID = checkpoint.id
        // 写入顺序由 PersistenceManager 保证：evidence → checkpoint → job
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        await eventRecorder.record(HoloAgentTelemetryEvent(name: .jobCreated, timestamp: now, job: job))
        return job
    }

    /// 创建并启动一个真实深度分析 job；触发来源由入口显式传递，默认是用户对话。
    /// 写入初始 checkpoint（含用户问题），供 runLoop 多轮推进。生产路径用。
    func startAnalysisJob(question: String, trigger: HoloAgentTrigger = .userQuestion,
                          sourceMessageID: UUID? = nil, now: Date = Date()) async throws -> HoloAgentJob {
        let resolvedComparison = Self.resolveQuestionComparison(question, referenceDate: now)
        var job = HoloAgentJob(
            id: UUID().uuidString, type: .deepAnalysis, userQuestion: question,
            trigger: trigger, state: .running, currentStep: .plan,
            createdAt: now, updatedAt: now,
            lastForegroundRunAt: nil, timeRange: resolvedComparison?.current.timeRange ?? Self.resolveQuestionTimeRange(question, referenceDate: now),
            budget: HoloAgentBudget.normalDeep(now: now),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil,
            referenceDate: now, snapshotCutoffAt: now,
            absoluteDeadline: now.addingTimeInterval(HoloAgentJob.absoluteDeadlineInterval)
        )
        if let baseline = resolvedComparison?.baseline.timeRange {
            job.baseline = baseline
        }
        job.sourceMessageID = sourceMessageID
        let queryService: HoloMemoryQueryService?
        if let memoryQueryService {
            queryService = memoryQueryService
        } else {
            #if HOLO_MEMORY_STANDALONE
            // standalone 编译不挂生产记忆栈（沿用项目既有 HOLO_MEMORY_STANDALONE 开关）
            queryService = nil
            #else
            queryService = try? await HoloMemoryQueryService.live()
            #endif
        }
        let memoryContext: HoloMemoryQueryContext?
        if let queryService {
            memoryContext = try? await queryService.query(
                question: question,
                consumer: .agent,
                now: now
            )
        } else {
            memoryContext = nil
        }
        let memorySummary = memoryContext.map(HoloMemorySummaryProvider.makeSummary(from:))
            ?? HoloMemorySummaryProvider.emptySummary
        let memoryEvidence = Self.memoryEvidenceRecords(
            from: memoryContext?.records ?? [],
            summary: memorySummary,
            jobID: job.id,
            now: now
        )
        var conversation: [HoloAgentMessage] = []
        if !memoryEvidence.isEmpty {
            conversation.append(Self.memoryContextMessage(
                summary: memorySummary,
                evidence: memoryEvidence,
                now: now
            ))
        }
        conversation.append(Self.mockUserMessage(question, now))
        let checkpoint = Self.makeCheckpoint(
            jobID: job.id, step: .plan, completedSteps: [],
            conversation: conversation,
            evidenceRecordIDs: memoryEvidence.map(\.id),
            memoryCandidateIDs: memorySummary.sourceIDs,
            now: now,
            inputSnapshotHash: HoloAgentInputSnapshotHasher.hash(for: job)
        )
        job.checkpointID = checkpoint.id
        try await saveProgress(job: job, evidence: memoryEvidence, checkpoint: checkpoint)
        await eventRecorder.record(HoloAgentTelemetryEvent(name: .jobCreated, timestamp: now, job: job))
        return job
    }

    /// 完成当前 step，推进到序列中的下一步并写新 checkpoint。
    /// 非运行态（已取消/已完成）不推进；序列走完后进入 completed。
    @discardableResult
    func completeCurrentStep(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = try await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        guard job.state == .running else { return job }

        let current = job.currentStep
        guard let index = Self.mockSequence.firstIndex(of: current) else {
            throw HoloAgentRuntimeError.unknownStep(current)
        }

        let latest = try await checkpointStore.latestForJob(jobID: jobID)
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
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        return job
    }

    /// 从最新 checkpoint 恢复（模拟 app 重启后继续）。
    /// 对齐 job.currentStep 与 checkpoint.step；终态任务不恢复。
    @discardableResult
    func resume(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = try await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        // 已结束的任务不复活
        guard !Self.terminalStates.contains(job.state) else { return job }

        guard let checkpoint = try await checkpointStore.latestForJob(jobID: jobID) else {
            throw HoloAgentRuntimeError.checkpointMissing(jobID)
        }
        job.currentStep = checkpoint.step
        job.checkpointID = checkpoint.id
        if job.state != .running { job.state = .running }
        job.updatedAt = now
        try await jobStore.upsert(job)
        return job
    }

    /// 取消任务：状态置为 cancelled，不再继续执行。§5.2：结算 active runtime 段。
    @discardableResult
    func cancel(jobID: String, now: Date = Date()) async throws -> HoloAgentJob {
        guard var job = try await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        job.state = .cancelled
        job.updatedAt = now
        job.endActiveSegment(at: now)
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
    /// §5.5：读取失败上抛，由调用方决定降级展示，不得当空结果。
    func loadLatestResult() async throws -> HoloAgentResult? {
        try await persistence.loadLatestResult()
    }

    /// 读取指定 IDs 的 evidence 记录，供结果渲染引用（Phase 6.3 evidence 引用）。
    func loadEvidence(forIDs ids: [String]) async throws -> [HoloEvidenceRecord] {
        try await persistence.loadEvidence(forIDs: ids)
    }

    /// 读取指定 job 的 Agent 结果，供 Chat 恢复回填。
    func loadResult(jobID: String) async throws -> HoloAgentResult? {
        try await persistence.loadResult(jobID: jobID)
    }

    /// 读取已到终态且带 Chat 来源消息的 job，供回前台后回填原 streaming 消息。
    func loadChatRecoverableTerminalJobs() async throws -> [HoloAgentJob] {
        let jobs = try await jobStore.load()
        return jobs.filter { job in
            job.sourceMessageID != nil && Self.terminalStates.contains(job.state)
        }
    }

    /// 读取所有带 Chat 来源消息的 job，供 Chat 页面重建/回前台时同步真实进度。
    func loadChatLinkedJobs() async throws -> [HoloAgentJob] {
        let jobs = try await jobStore.load()
        return jobs.filter { $0.sourceMessageID != nil }
    }

    /// 多轮 agent_loop：循环调用 LLM，按 status 推进，直到 final_claims 或轮数耗尽。
    /// 需要 llmClient 与 toolExecutor（未配置时抛 loopNotConfigured）。
    /// 注：循环条件含 wallTime 超时（§9.6）；Date() 不可注入但逻辑简单，测试靠 FakeLLM 同步快避免超时。
    /// - Parameter generation: 执行代次（§6.2）。生产必须经 Scheduler acquire 后传入；
    ///   每次写 checkpoint/evidence/result 与 LLM 响应应用前校验，过期抛 staleExecution 不得写回。
    ///   nil 仅限 mock/测试路径（不校验）。
    /// - Parameter progressReporter: §9.4 进度上报回调（每次 checkpoint 落盘后一次，避免高频刷新；
    ///   Scheduler 注入当前租约的 report，continued lease 据此更新系统进度）。
    func runLoop(jobID: String, generation: Int? = nil, systemTemplate: String, toolDescriptions: String,
                 progressReporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)? = nil,
                 now: Date = Date()) async throws -> HoloAgentJob {
        guard let llmClient, let toolExecutor else {
            throw HoloAgentRuntimeError.loopNotConfigured
        }
        guard var job = try await loadJob(jobID) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        guard !Self.terminalStates.contains(job.state) else { return job }
        // §5.2：绝对截止兜底——超过截止的 job 不再启动/恢复，直接失败，防止无限等待
        if job.isPastAbsoluteDeadline(at: now) {
            job.state = .failed
            job.errorSummary = "任务已超过截止时限，不再继续"
            job.waitReason = nil
            job.updatedAt = now
            job.endActiveSegment(at: now)
            try await guardExecutionGeneration(generation, jobID: jobID)
            try await jobStore.upsert(job)
            return job
        }
        // §5.2 active runtime：进入执行，开段计时并清除等待原因
        job.beginActiveSegment(at: now)
        job.waitReason = nil
        if job.timeRange == nil,
           let question = job.userQuestion {
            let resolvedComparison = Self.resolveQuestionComparison(question, referenceDate: now)
            if let comparison = resolvedComparison {
                job.timeRange = comparison.current.timeRange
                if job.baseline == nil { job.baseline = comparison.baseline.timeRange }
            } else if let resolvedRange = Self.resolveQuestionTimeRange(question, referenceDate: now) {
                job.timeRange = resolvedRange
            }
        }

        var checkpoint = try await checkpointStore.latestForJob(jobID: jobID)
            ?? Self.makeCheckpoint(jobID: jobID, step: .plan, completedSteps: [],
                                   conversation: [], now: now)
        try await executeDeterministicPrerequisiteToolsIfNeeded(
            job: &job,
            checkpoint: &checkpoint,
            generation: generation,
            progressReporter: progressReporter,
            now: now
        )
        var endedOnResponseContractFailure = false

        // §5.2：预算判断改用 active runtime（锁屏/等待/暂停不计入）
        while job.budget.consumedLLMRounds < job.budget.maxLLMRounds,
              !job.isActiveRuntimeExhausted(at: now) {
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

            // §5.3 step 幂等：请求前持久化 prepared request record（产品默认开启；
            // 恢复时 pending 为 prepared/completed 且 hash 一致 → 复用同一 stepID 重新请求，
            // 后端幂等返回同一响应；applied 或 hash 不一致 → 生成新 record）。
            let stepRecord: HoloAgentLLMRequestRecord?
            if stepIdempotencyEnabled {
                let requestHash = HoloAgentInputSnapshotHasher.canonicalHash(for: messages)
                let pending = checkpoint.pendingLLMRequest
                if let pending, pending.status != .applied, pending.requestHash == requestHash {
                    stepRecord = pending
                } else {
                    let revision = (checkpoint.revision ?? 0) + 1
                    checkpoint.revision = revision
                    checkpoint.executionGeneration = generation
                    stepRecord = HoloAgentLLMRequestRecord(
                        runID: job.id,
                        stepID: "llm-\(job.budget.consumedLLMRounds + 1)-\(revision)",
                        requestHash: requestHash,
                        status: .prepared,
                        responseHash: nil
                    )
                }
                checkpoint.pendingLLMRequest = stepRecord
                try await guardExecutionGeneration(generation, jobID: jobID)
                try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
                await reportProgress(job, to: progressReporter)
            } else {
                stepRecord = nil
            }

            let raw: String
            do {
                raw = try await llmClient.next(messages: messages, step: stepRecord)
            } catch {
                // §8.2：STEP_ID_CONFLICT（同一 stepID 不同 payload，协议冲突不可恢复）→ 置 failed
                if let apiError = error as? APIError, case .stepIdConflict(let message) = apiError {
                    try await guardExecutionGeneration(generation, jobID: jobID)
                    job.state = .failed
                    job.errorSummary = "请求步标识冲突（STEP_ID_CONFLICT）：\(message ?? "同一 step 提交了不同内容")"
                    job.waitReason = nil
                    job.updatedAt = now
                    job.endActiveSegment(at: now)
                    try await jobStore.upsert(job)
                    return job
                }
                // §7.2：可恢复网络错误 → 保存 checkpoint 并进入 waitingForCondition+network，不落失败
                if Self.isRecoverableNetworkError(error) {
                    return try await enterWaitingForCondition(
                        job: &job, checkpoint: checkpoint,
                        reason: .network,
                        failureSummary: "任务超过截止时限仍未等到网络恢复",
                        generation: generation, now: now
                    )
                }
                // 坏 JSON、SSE 不完整或响应信封解码失败属于单轮契约故障，
                // 不应直接终止整个用户任务。消耗一次 LLM 轮次后换新 step 纠错重试，
                // 直到真正触达用户设置的轮数/运行时限制。
                if Self.isRecoverableResponseContractError(error) {
                    try await guardExecutionGeneration(generation, jobID: jobID)
                    job.budget.consumedLLMRounds += 1
                    if job.budget.consumedLLMRounds < job.budget.maxLLMRounds {
                        try await prepareResponseContractRetry(
                            job: &job,
                            checkpoint: &checkpoint,
                            generation: generation,
                            progressReporter: progressReporter,
                            now: now
                        )
                        continue
                    }
                    endedOnResponseContractFailure = true
                    checkpoint.pendingLLMRequest = nil
                    break
                }
                throw error
            }
            // §6.2：LLM 响应返回后、应用前校验 generation（旧代次晚返回不得写回）
            try await guardExecutionGeneration(generation, jobID: jobID)
            job.budget.consumedLLMRounds += 1

            // §5.3：响应身份落盘（completed + responseHash）
            if stepIdempotencyEnabled, var record = stepRecord {
                record.status = .completed
                record.responseHash = HoloAgentInputSnapshotHasher.canonicalHash(for: raw)
                checkpoint.pendingLLMRequest = record
                try await guardExecutionGeneration(generation, jobID: jobID)
                try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
                await reportProgress(job, to: progressReporter)
            }

            let output: HoloAgentOutput
            do {
                let remainingRounds = job.budget.maxLLMRounds - job.budget.consumedLLMRounds
                output = try HoloAgentResponseParser.parse(raw, remainingRetries: remainingRounds)
            } catch HoloAgentError.outputParseFailure(let needsRetry) {
                if needsRetry {
                    try await prepareResponseContractRetry(
                        job: &job,
                        checkpoint: &checkpoint,
                        generation: generation,
                        progressReporter: progressReporter,
                        now: now
                    )
                    continue
                }
                let fallbackClaims = Self.fallbackClaims(
                    toolResults: checkpoint.completedToolResults,
                    patternSignals: checkpoint.patternSignals
                )
                if !fallbackClaims.isEmpty {
                    checkpoint.conversationState.append(Self.fallbackAssistantMessage(claims: fallbackClaims, now: now))
                    checkpoint.step = .verifyClaims
                    return try await completeWithClaims(fallbackClaims, job: &job, checkpoint: checkpoint,
                                                        generation: generation,
                                                        progressReporter: progressReporter, now: now)
                }
                // 没有工具事实可兜底时，只能在 LLM 轮数真正耗尽后结束；
                // 不再使用独立的 2 次 parser 上限提前杀死任务。
                endedOnResponseContractFailure = true
                checkpoint.pendingLLMRequest = nil
                break
            }

            checkpoint.retryCountByStep.removeValue(forKey: Self.responseContractRetryKey)
            checkpoint.conversationState.removeAll {
                $0.content.contains(Self.responseContractRecoveryMarker)
            }
            checkpoint.conversationState.append(Self.assistantMessage(for: output, now: now))
            // §5.3：输出已应用 → 标记 applied（随本分支下一次 saveProgress 一并落盘，不额外写盘；
            // 之后崩溃恢复按 completed 复用重放，工具去重逻辑保证不重复执行）
            if stepIdempotencyEnabled, var record = checkpoint.pendingLLMRequest {
                record.status = .applied
                checkpoint.pendingLLMRequest = record
            }

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
                    let isPlannedQuery = scopedRequest.dynamicPlan != nil || scopedRequest.crossDomainPlan != nil
                    let invalidDynamicAttempts = checkpoint.completedToolResults.filter {
                        $0.tool == scopedRequest.tool
                            && $0.error?.code == HoloToolErrorCode.invalidParams
                            && isPlannedQuery
                    }.count
                    let rawResult: HoloDataToolResult
                    if isPlannedQuery, invalidDynamicAttempts >= 2 {
                        rawResult = HoloDataToolResult(
                            toolRequestID: scopedRequest.id,
                            tool: scopedRequest.tool,
                            status: .error,
                            coverage: nil,
                            metrics: [],
                            events: [],
                            warnings: [],
                            error: HoloToolError(
                                code: "DYNAMIC_PLAN_RETRY_EXHAUSTED",
                                message: "动态查询计划已修正一次，停止继续重试",
                                recoverable: false
                            )
                        )
                    } else {
                        rawResult = await toolExecutor.execute(scopedRequest)
                    }
                    // §7.2：健康数据锁屏不可读 → 保存 checkpoint 并进入等待解锁，
                    // 不算失败、不记录该工具结果（恢复后重新查询），禁止生成伪零证据
                    if let toolError = rawResult.error,
                       toolError.recoverable,
                       toolError.code == HoloToolErrorCode.deviceLocked {
                        return try await enterWaitingForCondition(
                            job: &job, checkpoint: checkpoint,
                            reason: .deviceUnlock,
                            failureSummary: "任务超过截止时限仍未等到设备解锁",
                            generation: generation, now: now
                        )
                    }
                    let result = Self.resultWithCanonicalEvidenceIDs(rawResult, jobID: job.id)
                    checkpoint.completedToolResults.append(result)
                    let evidence = Self.evidenceRecords(
                        from: result,
                        request: scopedRequest,
                        jobID: job.id,
                        now: now
                    )
                    checkpoint.evidenceRecordIDs.append(contentsOf: evidence.map(\.id))
                    // §6.2：写 checkpoint/evidence 前校验 generation
                    try await guardExecutionGeneration(generation, jobID: jobID)
                    try await saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)
                    await reportProgress(job, to: progressReporter)
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
                try await guardExecutionGeneration(generation, jobID: jobID)
                try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
                await reportProgress(job, to: progressReporter)
            case .needMoreAnalysis:
                checkpoint.step = .continueOrConclude
                try await guardExecutionGeneration(generation, jobID: jobID)
                try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
                await reportProgress(job, to: progressReporter)
            case .finalClaims:
                checkpoint.step = .verifyClaims
                return try await completeWithClaims(output.claims, job: &job, checkpoint: checkpoint,
                                                    generation: generation,
                                                    progressReporter: progressReporter, now: now)
            }
        }

        let fallbackClaims = Self.fallbackClaims(
            toolResults: checkpoint.completedToolResults,
            patternSignals: checkpoint.patternSignals
        )
        if !fallbackClaims.isEmpty {
            checkpoint.conversationState.append(Self.fallbackAssistantMessage(claims: fallbackClaims, now: now))
            checkpoint.step = .verifyClaims
            return try await completeWithClaims(fallbackClaims, job: &job, checkpoint: checkpoint,
                                                generation: generation,
                                                progressReporter: progressReporter, now: now)
        }

        try await guardExecutionGeneration(generation, jobID: jobID)
        job.state = .failed
        // §5.2：区分预算耗尽原因——active runtime 超时与 LLM 轮数耗尽文案不同
        if job.isActiveRuntimeExhausted(at: now) {
            job.errorSummary = "Agent 运行时长预算耗尽（实际执行时长超限）"
        } else if endedOnResponseContractFailure {
            job.errorSummary = "Agent 预算耗尽（LLM 轮数上限；最后一轮响应未通过结构校验）"
        } else {
            job.errorSummary = "Agent 预算耗尽（LLM 轮数上限）"
        }
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await jobStore.upsert(job)
        return job
    }

    // MARK: - 后台/前台生命周期

    /// 进入后台：把运行中任务标记为 waitingForForeground + waitReason=backgroundTimeExpired，便于前台恢复。
    /// §5.2：同时结算 active runtime 段（锁屏/后台等待不计入运行预算）。
    func pauseForBackground(now: Date = Date()) async throws {
        let jobs = try await jobStore.load()
        for var job in jobs where job.state == .running
            || job.state == .waitingForLLM
            || job.state == .retrying {
            job.state = .waitingForForeground
            job.waitReason = .backgroundTimeExpired
            job.lastForegroundRunAt = now
            job.updatedAt = now
            job.endActiveSegment(at: now)
            try await jobStore.upsert(job)
        }
    }

    /// 回到前台：恢复所有未结束（非终态、非 running）的任务，返回恢复数量。
    /// 注：本方法仅标记状态、不重启推理；真正闭合恢复链由 HoloAgentScheduler.resumeAndContinue 负责。
    @discardableResult
    func resumeUnfinishedJobs(now: Date = Date()) async throws -> Int {
        let jobs = try await jobStore.load()
        var resumed = 0
        for job in jobs
            where !Self.terminalStates.contains(job.state) && job.state != .running {
            do {
                _ = try await resume(jobID: job.id, now: now)
                resumed += 1
            } catch {
                // 单 job 恢复失败不阻塞其余 job；原因落日志（不静默 try?，§十 Phase 1 任务 2）
                NSLog("[Agent] resumeUnfinishedJobs 单任务恢复失败 jobID=\(job.id) error=\(String(describing: error))")
            }
        }
        return resumed
    }

    /// 收集所有非终态 job 的 ID（含 running 孤儿与 waitingForForeground），供 Scheduler 拉起 runLoop。
    /// 与 resumeUnfinishedJobs 的区别：不排除 running（进程被硬杀的孤儿落盘仍是 running）、不修改状态——
    /// 是否真正重启推理由 Scheduler 决定，本方法只负责给出「需要被推进」的 job 清单。
    /// §5.2：paused（用户明确暂停）不自动恢复；§5.5：枚举场景读失败必须上抛，不得当空库继续。
    func collectResumableJobIDs(now: Date = Date()) async throws -> [String] {
        let jobs = try await jobStore.load()
        return jobs.filter { !Self.terminalStates.contains($0.state) && $0.state != .paused }.map(\.id)
    }

    /// 收集所有非终态 job（含 running 孤儿），供 Scheduler 排序、限量、拉起 runLoop。
    /// §5.2：paused 不自动恢复；§5.5：枚举场景读失败必须上抛，不得当空库继续。
    func collectResumableJobs(now: Date = Date()) async throws -> [HoloAgentJob] {
        let jobs = try await jobStore.load()
        return jobs.filter { !Self.terminalStates.contains($0.state) && $0.state != .paused }
    }

    /// 返回某 job 的最新 checkpoint，供 Scheduler 恢复前校验 inputSnapshotHash。
    func latestCheckpointForJob(jobID: String) async throws -> HoloAgentCheckpoint? {
        try await checkpointStore.latestForJob(jobID: jobID)
    }

    /// 把某 job 最新 checkpoint 的 inputSnapshotHash 重建为稳定 SHA-256（§5.1 兼容迁移：
    /// 旧 Hasher 值/缺失不用于拒绝恢复，恢复前重写为稳定值）。无 checkpoint 时无操作。
    func refreshStableInputSnapshotHash(jobID: String, hash: String, now: Date = Date()) async throws {
        guard var checkpoint = try await checkpointStore.latestForJob(jobID: jobID) else { return }
        checkpoint.inputSnapshotHash = hash
        checkpoint.schemaVersion = checkpoint.schemaVersion ?? 1
        checkpoint.updatedAt = now
        try await checkpointStore.upsert(checkpoint)
    }

    /// 输入快照确认不匹配：把跳过原因落盘到 job（needs-replan 语义），不得静默跳过（§十 Phase 1 任务 2）。
    func recordInputSnapshotMismatch(jobID: String, now: Date = Date()) async throws {
        try await recordExecutionSkip(
            jobID: jobID,
            reason: "任务输入已变化（inputSnapshotHash 不匹配），不再自动恢复，请重新发起分析",
            now: now
        )
    }

    /// 执行/恢复被跳过（并发门控、恢复失败等）：把原因落盘到 job.errorSummary，不静默（§6.1）。
    func recordExecutionSkip(jobID: String, reason: String, now: Date = Date()) async throws {
        guard var job = try await loadJob(jobID) else { return }
        job.errorSummary = reason
        job.updatedAt = now
        try await jobStore.upsert(job)
    }

    /// 把单个非终态任务标记为等待（Scheduler.pause 用；§6.4 只做状态标记 + 取消信号，
    /// 不承担完整 checkpoint 保存——正常推进中已持续落盘）。
    /// §5.2：结算 active runtime 段，并按原因写 waitReason。
    @discardableResult
    func pauseJob(jobID: String, reason: HoloAgentWaitReason = .backgroundTimeExpired, now: Date = Date()) async throws -> HoloAgentJob? {
        guard var job = try await loadJob(jobID) else { return nil }
        guard !Self.terminalStates.contains(job.state) else { return job }
        if job.state == .running || job.state == .waitingForLLM || job.state == .retrying {
            job.state = .waitingForForeground
            job.waitReason = reason
        }
        job.lastForegroundRunAt = now
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await jobStore.upsert(job)
        return job
    }

    /// 把 job 置 superseded 终态（被新任务取代，§5.2；Phase 2 P0 抢占用）。
    @discardableResult
    func supersedeJob(jobID: String, now: Date = Date()) async throws -> HoloAgentJob? {
        guard var job = try await loadJob(jobID) else { return nil }
        job.state = .superseded
        job.waitReason = .inputChanged
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await jobStore.upsert(job)
        return job
    }

    /// 把 job 置 paused（系统结束执行，§9.5 不自动复活），记录来源与 waitReason=.systemCapacity。
    @discardableResult
    func suspendJob(jobID: String, reason: String, now: Date = Date()) async throws -> HoloAgentJob? {
        guard var job = try await loadJob(jobID) else { return nil }
        guard !Self.terminalStates.contains(job.state) else { return job }
        job.state = .paused
        job.waitReason = .systemCapacity
        job.errorSummary = reason
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await jobStore.upsert(job)
        return job
    }

    /// 把 job 置 failed 并写原因（绝对截止/不可恢复错误用），结算 active runtime 段。
    @discardableResult
    func failJob(jobID: String, reason: String, now: Date = Date()) async throws -> HoloAgentJob? {
        guard var job = try await loadJob(jobID) else { return nil }
        job.state = .failed
        job.errorSummary = reason
        job.waitReason = nil
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await jobStore.upsert(job)
        return job
    }

    /// 记录最近一次恢复/启动原因（§5.2 lastResumeReason，诊断用）。
    func recordResumeReason(jobID: String, reason: HoloAgentResumeReason, now: Date = Date()) async throws {
        guard var job = try await loadJob(jobID) else { return }
        job.lastResumeReason = reason
        job.updatedAt = now
        try await jobStore.upsert(job)
    }

    /// 清理终态且超保留期的 job 及其关联 checkpoint/result（透传 persistence，§9.6 体积治理）。
    @discardableResult
    func cleanupTerminalJobs(policy: HoloJobCleanupPolicy, now: Date = Date()) async throws -> [String] {
        try await persistence.cleanupTerminalJobs(policy: policy, now: now)
    }

    // MARK: - 内部辅助

    /// 所有 checkpoint 提交统一经过此处，确保 Phase 7 诊断事件与真实落盘一一对应。
    /// 事件只记录 step identity/计数，不读取 conversation、tool result 或 evidence 内容。
    private func saveProgress(
        job: HoloAgentJob,
        evidence: [HoloEvidenceRecord],
        checkpoint: HoloAgentCheckpoint
    ) async throws {
        try await persistence.saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)
        await eventRecorder.record(HoloAgentTelemetryEvent(
            name: .checkpointCommitted,
            job: job,
            checkpointRevision: checkpoint.revision,
            requestID: checkpoint.pendingLLMRequest?.stepID
        ))
    }

    /// 响应契约失败的恢复点：持久化重试次数和纠错指令，并清掉已完成的坏 step。
    /// 即使 App 在两轮之间被杀，恢复后也不会从后端幂等缓存重放同一份坏响应。
    private func prepareResponseContractRetry(
        job: inout HoloAgentJob,
        checkpoint: inout HoloAgentCheckpoint,
        generation: Int?,
        progressReporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)?,
        now: Date
    ) async throws {
        let attempt = (checkpoint.retryCountByStep[Self.responseContractRetryKey] ?? 0) + 1
        checkpoint.retryCountByStep[Self.responseContractRetryKey] = attempt
        checkpoint.pendingLLMRequest = nil
        checkpoint.conversationState.removeAll {
            $0.content.contains(Self.responseContractRecoveryMarker)
        }
        checkpoint.conversationState.append(Self.responseContractRecoveryMessage(attempt: attempt, now: now))
        checkpoint.updatedAt = now
        job.state = .retrying
        job.errorSummary = nil
        job.updatedAt = now
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        await reportProgress(job, to: progressReporter)
    }

    private func loadJob(_ jobID: String) async throws -> HoloAgentJob? {
        try await jobStore.load().first { $0.id == jobID }
    }

    private static func makeCheckpoint(
        jobID: String, step: HoloAgentStep, completedSteps: [HoloAgentStep],
        conversation: [HoloAgentMessage], patternSignals: [HoloPatternSignal] = [],
        evidenceRecordIDs: [String] = [],
        memoryCandidateIDs: [String] = [],
        now: Date,
        inputSnapshotHash: String? = nil
    ) -> HoloAgentCheckpoint {
        HoloAgentCheckpoint(
            id: UUID().uuidString, jobID: jobID, step: step, completedSteps: completedSteps,
            conversationState: conversation, pendingToolRequests: [], completedToolResults: [],
            patternSignals: patternSignals, evidenceRecordIDs: evidenceRecordIDs, validatedClaimIDs: [],
            memoryCandidateIDs: memoryCandidateIDs, retryCountByStep: [:],
            createdAt: now, updatedAt: now,
            schemaVersion: inputSnapshotHash == nil ? nil : 1,
            inputSnapshotHash: inputSnapshotHash
        )
    }

    private static func resolveQuestionTimeRange(_ question: String, referenceDate: Date) -> HoloAgentTimeRange? {
        HoloAgentTimeSemanticResolver.resolve(question, referenceDate: referenceDate)?.timeRange
    }

    /// 解析对比类问题（如“本月比上月消费多在哪”）的双时间窗。
    /// 命中对比配对时返回 (current, baseline)；否则返回 nil，调用方回退单窗语义。
    private static func resolveQuestionComparison(_ question: String, referenceDate: Date) -> HoloAgentResolvedComparison? {
        HoloAgentTimeSemanticResolver.resolveComparison(question, referenceDate: referenceDate)
    }

    private static func requestWithJobScope(_ request: HoloToolRequest, job: HoloAgentJob) -> HoloToolRequest {
        var scoped = request
        if scoped.timeRange == nil, let jobRange = job.timeRange {
            scoped.timeRange = jobRange
        }
        // 注入对比期窗口：对比类问题（如“本月比上月”）解析出的 baseline 从 job 透传到 request。
        // 优先级：LLM 显式 request.baseline > job.baseline（确定性解析）> DataSource 内部回退。
        if scoped.baseline == nil, let jobBaseline = job.baseline {
            scoped.baseline = jobBaseline
        }
        if var plan = scoped.dynamicPlan {
            if plan.timeRange == nil { plan.timeRange = scoped.timeRange }
            if plan.baseline == nil { plan.baseline = scoped.baseline }
            scoped.dynamicPlan = plan
        }
        if var plan = scoped.crossDomainPlan {
            if plan.timeRange == nil { plan.timeRange = scoped.timeRange }
            scoped.crossDomainPlan = plan
        }
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
        generation: Int? = nil,
        progressReporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)? = nil,
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
            // §6.2：写 checkpoint/evidence 前校验 generation
            try await guardExecutionGeneration(generation, jobID: job.id)
            try await saveProgress(job: job, evidence: evidence, checkpoint: checkpoint)
            await reportProgress(job, to: progressReporter)
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
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        await reportProgress(job, to: progressReporter)
    }

    /// §8.1 step 幂等内部策略（产品默认开启；关闭时走旧路径：不生成/发送 step 字段、
    /// 不持久化 request record）。nonisolated：HoloMemorySettings 非 actor 隔离，可直接读。
    private nonisolated var stepIdempotencyEnabled: Bool {
        HoloAIFeatureFlags.agentStepIdempotencyEnabled
    }

    /// §6.2 generation guard：副作用写盘前校验执行未取消且 generation 仍有效，
    /// 过期（被新执行取代）抛 `staleExecution`，已取消抛 CancellationError，
    /// 不得写回任何 checkpoint/evidence/result/job 状态。
    /// generation 为 nil 时（mock/测试路径）不校验代次（仍检查取消）。
    private func guardExecutionGeneration(_ generation: Int?, jobID: String) async throws {
        try Task.checkCancellation()
        guard let generation else { return }
        let valid = try await jobStore.validateExecutionGeneration(jobID: jobID, generation: generation)
        guard valid else {
            var event = HoloAgentTelemetryEvent(
                name: .executionStaleRejected,
                generation: generation,
                errorCode: "STALE_EXECUTION"
            )
            event.jobID = jobID
            await eventRecorder.record(event)
            throw HoloAgentRuntimeError.staleExecution(jobID: jobID, generation: generation)
        }
    }

    /// §9.4：checkpoint 落盘后上报一次进度（无 reporter 时空操作）。
    private func reportProgress(_ job: HoloAgentJob,
                                to reporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)?) async {
        guard let reporter else { return }
        await reporter(HoloAgentProgressSnapshot(job: job))
    }

    /// §7.2 等待条件一等公民：先保存 checkpoint（可恢复断点），
    /// 再把 job 置 waitingForCondition + waitReason 落盘，正常返回（不算失败）。
    /// 已超过绝对截止 → 置 failed（failureSummary），防止无限等待。
    private func enterWaitingForCondition(
        job: inout HoloAgentJob,
        checkpoint: HoloAgentCheckpoint,
        reason: HoloAgentWaitReason,
        failureSummary: String,
        generation: Int?,
        now: Date
    ) async throws -> HoloAgentJob {
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        job.endActiveSegment(at: now)
        if job.isPastAbsoluteDeadline(at: now) {
            job.state = .failed
            job.errorSummary = failureSummary
            job.waitReason = nil
        } else {
            job.state = .waitingForCondition
            job.waitReason = reason
            job.errorSummary = nil
        }
        job.updatedAt = now
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await jobStore.upsert(job)
        await eventRecorder.record(HoloAgentTelemetryEvent(
            name: job.state == .waitingForCondition ? .waitingForCondition : .jobFailed,
            timestamp: now,
            job: job,
            checkpointRevision: checkpoint.revision,
            errorCode: job.state == .failed ? "WAIT_DEADLINE_EXCEEDED" : nil,
            requestID: checkpoint.pendingLLMRequest?.stepID
        ))
        return job
    }

    /// §7.2 可恢复网络错误判定：APIError 的网络不可用/超时与 URLError 的连接类错误。
    private static func isRecoverableNetworkError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .networkUnavailable, .timeout, .serverError:
                return true
            case .backendError(let statusCode, let code, _, _):
                let transientCodes = [
                    "MODEL_UNAVAILABLE",
                    "UPSTREAM_TIMEOUT",
                    "UPSTREAM_ERROR",
                    "SERVICE_UNAVAILABLE"
                ]
                return statusCode >= 500 && transientCodes.contains(code ?? "")
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// 响应结构/流完整性错误可以通过新 step 重新生成，不应把整个 job 判死。
    private static func isRecoverableResponseContractError(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .decodingError:
            return true
        case .backendError(_, let code, _, _):
            return [
                "INVALID_AGENT_JSON",
                "UPSTREAM_SSE_INVALID_FRAME",
                "UPSTREAM_SSE_INCOMPLETE",
                "TRUNCATED_MODEL_RESPONSE",
                "EMPTY_MODEL_RESPONSE"
            ].contains(code ?? "")
        default:
            return false
        }
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

    private static func memoryContextMessage(
        summary: HoloMemoryPromptSummary,
        evidence: [HoloEvidenceRecord],
        now: Date
    ) -> HoloAgentMessage {
        let evidenceByMemoryID = Dictionary(
            uniqueKeysWithValues: evidence.compactMap { record in
                record.referencedByMemoryIDs.first.map { ($0, record.id) }
            }
        )
        let lines = summary.entries.compactMap { entry -> String? in
            guard let evidenceID = evidenceByMemoryID[entry.id] else { return nil }
            return "- [evidence_id=\(evidenceID)] [memory_id=\(entry.id)] \(entry.title)：\(entry.aiUseSummary)"
        }
        let content = """
        长期记忆背景（确定性预取；当前问题与工具数据优先）：
        \(lines.joined(separator: "\n"))
        如果结论实际使用某条记忆，metricAssertion.metricKey 使用 memory.context，并引用对应 evidence_id；不得把记忆当作当前事实。
        """
        return HoloAgentMessage(
            role: .system,
            content: content,
            toolRequestID: nil,
            toolName: nil,
            timestamp: now,
            tokenEstimate: nil
        )
    }

    private static func memoryEvidenceRecords(
        from memories: [HoloMemoryRecord],
        summary: HoloMemoryPromptSummary,
        jobID: String,
        now: Date
    ) -> [HoloEvidenceRecord] {
        let memoriesByID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        return summary.entries.compactMap { entry in
            guard let memory = memoriesByID[entry.id] else { return nil }
            let evidenceID = "memory-context-\(jobID)-\(entry.id)"
            let sensitivity: HoloEvidenceSensitivity
            switch memory.sensitivity {
            case .normal: sensitivity = .normal
            case .highImpact: sensitivity = .highImpact
            case .sensitive: sensitivity = .sensitive
            }
            return HoloEvidenceRecord(
                id: evidenceID,
                dedupeKey: "\(jobID):memory:\(entry.id)",
                sourceModule: .memory,
                sourceID: entry.id,
                sourceKind: "long_term_memory",
                timeRange: nil,
                occurredAt: memory.updatedAt,
                metricKey: "memory.context",
                metricValue: nil,
                unit: nil,
                baselineValue: nil,
                comparison: nil,
                excerpt: sensitivity == .normal ? memory.displaySummary : "[敏感记忆摘要已脱敏]",
                redactedExcerpt: sensitivity == .normal ? entry.aiUseSummary : "[敏感记忆摘要已脱敏]",
                sensitivity: sensitivity,
                confidence: memory.confidenceScore,
                status: .active,
                generatedBy: "holo_memory_prefetch",
                generatedAt: now,
                referencedByJobIDs: [jobID],
                referencedByMemoryIDs: [entry.id],
                deviceID: nil
            )
        }
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

    private static let responseContractRetryKey = "response_contract"
    private static let responseContractRecoveryMarker = "[HOLO_AGENT_RESPONSE_RECOVERY_V1]"

    private static func responseContractRecoveryMessage(attempt: Int, now: Date) -> HoloAgentMessage {
        HoloAgentMessage(
            role: .system,
            content: """
            \(responseContractRecoveryMarker)
            上一轮输出未通过 Agent 协议校验，请重新生成完整 JSON，不要复述或解释错误。
            第 \(attempt) 次结构恢复要求：
            - toolRequests[].dynamicPlan 与 crossDomainPlan 必须和 parameters 同级，绝不能放进 parameters 内。
            - parameters 只能包含字符串键值；动态查询结构只放在 dynamicPlan/crossDomainPlan。
            - final_claims 必须包含至少一条 claim，toolRequests 必须为空数组。
            - 每条 claim 必须有非空 displayText、metricAssertions 和 evidenceIDs。
            - metricAssertions[] 必须使用 metricKey、数字或 null 的 value/baselineValue、unit、comparison、evidenceIDs；证据 ID 必须逐字复用工具结果。
            - status、reasoning、toolRequests、claims、warnings 必须齐全；不要输出 Markdown。
            """,
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
        generation: Int? = nil,
        progressReporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)? = nil,
        now: Date
    ) async throws -> HoloAgentJob {
        let availableEvidenceIDs = Array(Set(checkpoint.evidenceRecordIDs + claims.flatMap(\.evidenceIDs)))
        let evidence = try await persistence.loadEvidence(forIDs: availableEvidenceIDs)
        let verification = HoloClaimVerifier().verify(claims: claims, evidence: evidence)
        var acceptedClaims = verification.acceptedClaims
        if Self.shouldSuppressSuggestions(for: job.userQuestion) {
            acceptedClaims.removeAll { $0.type == "suggestion" }
        }
        let fallback = Self.fallbackClaims(
            toolResults: checkpoint.completedToolResults,
            patternSignals: acceptedClaims.isEmpty ? checkpoint.patternSignals : []
        )
        if !fallback.isEmpty {
            let fallbackEvidenceIDs = Array(Set(checkpoint.evidenceRecordIDs + fallback.flatMap(\.evidenceIDs)))
            let fallbackEvidence = try await persistence.loadEvidence(forIDs: fallbackEvidenceIDs)
            let verifiedFallback = HoloClaimVerifier()
                .verify(claims: fallback, evidence: fallbackEvidence)
                .acceptedClaims
            if acceptedClaims.isEmpty {
                acceptedClaims = verifiedFallback
            } else {
                // 模型只回答部分子问题时，用确定性结果补齐尚未覆盖的指标。
                var coveredKeys = Set(acceptedClaims.flatMap { $0.metricAssertions.map(\.metricKey) })
                for claim in verifiedFallback {
                    let missingAssertions = claim.metricAssertions.filter { !coveredKeys.contains($0.metricKey) }
                    guard !missingAssertions.isEmpty else { continue }
                    var supplement = claim
                    supplement.id += "-supplement"
                    supplement.metricAssertions = missingAssertions
                    supplement.evidenceIDs = Array(Set(missingAssertions.flatMap(\.evidenceIDs)))
                    let missingKeys = Set(missingAssertions.map(\.metricKey))
                    let metricText = checkpoint.completedToolResults
                        .flatMap(\.metrics)
                        .filter { missingKeys.contains($0.metricKey) }
                        .compactMap(Self.readableMetricText)
                        .joined(separator: "；")
                    if !metricText.isEmpty { supplement.displayText = metricText }
                    acceptedClaims.append(supplement)
                    coveredKeys.formUnion(missingAssertions.map(\.metricKey))
                }
            }
        }
        acceptedClaims = Self.deduplicatedClaims(acceptedClaims)
        let resultEvidenceIDs = Array(Set(acceptedClaims.flatMap(\.evidenceIDs)))
        let usedMemoryIDs = Array(Set(
            evidence
                .filter { resultEvidenceIDs.contains($0.id) }
                .flatMap(\.referencedByMemoryIDs)
        ))
        let coveredMetricKeys = Set(acceptedClaims.flatMap { $0.metricAssertions.map(\.metricKey) })
        let resultCoverage = checkpoint.completedToolResults.first { toolResult in
            toolResult.coverage != nil && toolResult.metrics.contains { coveredMetricKeys.contains($0.metricKey) }
        }?.coverage
        // canonical result ID：同一 job 恒为同一 ID，配合 ResultStore 按 jobID 唯一 upsert（§5.4，P0-6）
        let agentResult = HoloAgentResult(
            id: "agent-result:\(job.id)",
            jobID: job.id,
            title: "深度分析",
            summary: acceptedClaims.isEmpty
                ? "本期暂无显著观察"
                : acceptedClaims.map(\.displayText).joined(separator: "；"),
            claims: acceptedClaims,
            evidenceIDs: resultEvidenceIDs,
            memoryCandidateIDs: usedMemoryIDs,
            status: "completed",
            generatedAt: now,
            updatedAt: now,
            coverage: resultCoverage
        )
        // §6.2：Result 提交与最终状态写回前校验 generation（过期不得写回）
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await persistence.saveResult(agentResult)
        await reportProgress(job, to: progressReporter)
        job.resultID = agentResult.id
        job.state = .completed
        job.errorSummary = nil
        job.waitReason = nil
        job.updatedAt = now
        job.endActiveSegment(at: now)
        try await guardExecutionGeneration(generation, jobID: job.id)
        try await saveProgress(job: job, evidence: [], checkpoint: checkpoint)
        await reportProgress(job, to: progressReporter)
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
                formula: event.formula ?? result.metrics.first { $0.metricKey == metricKey }?.formula,
                sourceRecordIDs: event.sourceRecordIDs ?? result.metrics.first { $0.metricKey == metricKey }?.sourceRecordIDs,
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
        let toolClaims = toolResults.prefix(3).flatMap { result -> [HoloAgentClaim] in
            guard result.status == .success || result.status == .partial || result.status == .empty else {
                return []
            }
            if result.tool == "finance", result.toolRequestID.contains("spending_breakdown") {
                let claims = financeSpendingBreakdownFallbackClaims(from: result)
                if !claims.isEmpty { return claims }
            }
            if result.tool == "health" {
                return healthFallbackClaims(from: result)
            }
            if result.status == .empty {
                let message = result.warnings.first?.message ?? "所选时间范围内没有可用数据"
                return [HoloAgentClaim(
                    id: "fallback-\(result.toolRequestID)-empty", type: "empty",
                    displayText: message, metricAssertions: [], evidenceIDs: [],
                    prohibitedInferences: [], confidence: 1
                )]
            }
            let metric = result.metrics.first
            let event = result.events.first
            let evidenceIDsForMetric = metric.map { metric in
                result.events
                    .filter { $0.metricKey == metric.metricKey }
                    .map(\.id)
            } ?? []
            let relevantMetrics = result.metrics.filter { $0.value != nil }
            let assertions = relevantMetrics.compactMap { item -> HoloMetricAssertion? in
                let evidenceIDs = result.events.filter { $0.metricKey == item.metricKey }.map(\.id)
                guard !evidenceIDs.isEmpty else { return nil }
                return HoloMetricAssertion(metricKey: item.metricKey, value: item.value,
                                           baselineValue: item.baselineValue, unit: item.unit,
                                           comparison: item.comparison, evidenceIDs: evidenceIDs)
            }
            let text: String
            if !assertions.isEmpty {
                let metricTexts = relevantMetrics.compactMap { Self.readableMetricText($0) }
                let coverage = result.coverage.map { "数据覆盖 \($0.coveredDays)/\($0.totalDays) 天" }
                text = (metricTexts + [coverage].compactMap { $0 }).joined(separator: "；")
            } else if let metric {
                text = Self.fallbackDisplayText(for: result, metric: metric, event: event)
            } else if let event {
                text = event.excerpt
            } else {
                text = "所选时间范围内没有可展示的计算结果"
            }
            return [HoloAgentClaim(
                id: "fallback-\(result.toolRequestID)",
                type: "observation",
                displayText: text,
                metricAssertions: assertions.isEmpty ? (metric.map {
                    [HoloMetricAssertion(metricKey: $0.metricKey, value: $0.value,
                                         baselineValue: $0.baselineValue, unit: $0.unit,
                                         comparison: $0.comparison, evidenceIDs: evidenceIDsForMetric)]
                } ?? []) : assertions,
                evidenceIDs: assertions.isEmpty
                    ? (metric == nil ? result.events.map(\.id) : evidenceIDsForMetric)
                    : assertions.flatMap(\.evidenceIDs),
                prohibitedInferences: ["不要把并发现象表述为因果", "不要做心理、医疗、人格判断"],
                confidence: result.status == .empty ? 0.3 : 0.45
            )]
        }
        let hasDeterministicPresentation = toolResults.contains { result in
            result.tool == "health" ||
                (result.tool == "finance" && result.toolRequestID.contains("spending_breakdown"))
        }
        if hasDeterministicPresentation, !toolClaims.isEmpty { return toolClaims }

        let patternClaims = patternSignals.prefix(3).map { signal in
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
        return patternClaims.isEmpty ? toolClaims : patternClaims
    }

    private static func healthFallbackClaims(from result: HoloDataToolResult) -> [HoloAgentClaim] {
        guard result.status != .empty else {
            return [HoloAgentClaim(id: "fallback-\(result.toolRequestID)-empty", type: "empty",
                                   displayText: result.warnings.first?.message ?? "所选时间范围内没有可用的健康数据",
                                   metricAssertions: [], evidenceIDs: [], prohibitedInferences: [], confidence: 1)]
        }
        let metricByKey = Dictionary(result.metrics.map { ($0.metricKey, $0) }, uniquingKeysWith: { first, _ in first })
        let sleepKeys = ["health.sleep.average_hours", "health.sleep.recorded_nights", "health.sleep.low_days"]
        if let average = metricByKey[sleepKeys[0]]?.value {
            let nights = Int(metricByKey[sleepKeys[1]]?.value ?? Double(result.coverage?.coveredDays ?? 0))
            let low = Int(metricByKey[sleepKeys[2]]?.value ?? 0)
            let change = metricByKey[sleepKeys[0]]?.baselineValue.map { average - $0 }
            let changeText = change.map { "，相比上期\($0 >= 0 ? "增加" : "减少") \(String(format: "%.1f", abs($0))) 小时" }
                ?? "，上期有效记录不足，暂时无法比较"
            let hasStageData = result.metrics.contains { ["health.sleep.deep_hours", "health.sleep.core_hours", "health.sleep.rem_hours"].contains($0.metricKey) }
            let qualityDetails: String = hasStageData ? [
                metricByKey["health.sleep.deep_hours"]?.value.map { "平均深睡 \(String(format: "%.1f", $0)) 小时" },
                metricByKey["health.sleep.core_hours"]?.value.map { "核心睡眠 \(String(format: "%.1f", $0)) 小时" },
                metricByKey["health.sleep.rem_hours"]?.value.map { "REM \(String(format: "%.1f", $0)) 小时" },
                metricByKey["health.sleep.efficiency"]?.value.map { "睡眠效率 \(String(format: "%.0f", $0))%" },
                metricByKey["health.sleep.duration_variation_minutes"]?.value.map { "时长波动约 \(String(format: "%.0f", $0)) 分钟" },
                metricByKey["health.sleep.bedtime_variation_minutes"]?.value.map { "入睡时间波动约 \(String(format: "%.0f", $0)) 分钟" },
                metricByKey["health.sleep.wake_variation_minutes"]?.value.map { "起床时间波动约 \(String(format: "%.0f", $0)) 分钟" }
            ].compactMap { $0 }.joined(separator: "，") : ""
            let boundary = hasStageData
                ? "本次同时读取到睡眠阶段、效率与作息稳定性，可用于描述性质量分析。\(qualityDetails)\(qualityDetails.isEmpty ? "" : "。")"
                : "当前只能评估睡眠时长，不能完整判断睡眠质量。"
            let text = "最近平均睡眠 \(String(format: "%.1f", average)) 小时，有效记录 \(nights) 晚，低于 6 小时 \(low) 晚\(changeText)。\(boundary)"
            let assertions = result.metrics.compactMap { item -> HoloMetricAssertion? in
                let evidence = result.events.filter { $0.metricKey == item.metricKey }.map(\.id)
                guard !evidence.isEmpty else { return nil }
                return HoloMetricAssertion(metricKey: item.metricKey, value: item.value,
                                           baselineValue: item.baselineValue, unit: item.unit,
                                           comparison: item.comparison, evidenceIDs: evidence)
            }
            let capabilityIDs = result.events.filter { $0.metricKey == "health.sleep.capability" }.map(\.id)
            return [HoloAgentClaim(id: "fallback-\(result.toolRequestID)-sleep", type: "observation",
                                   displayText: text, metricAssertions: assertions,
                                   evidenceIDs: assertions.flatMap(\.evidenceIDs) + capabilityIDs,
                                   prohibitedInferences: ["不要把睡眠时长等同于完整睡眠质量", "不要做医疗诊断"], confidence: 0.8)]
        }
        let assertions = result.metrics.compactMap { item -> HoloMetricAssertion? in
            let evidence = result.events.filter { $0.metricKey == item.metricKey }.map(\.id)
            guard !evidence.isEmpty else { return nil }
            return HoloMetricAssertion(metricKey: item.metricKey, value: item.value,
                                       baselineValue: item.baselineValue, unit: item.unit,
                                       comparison: item.comparison, evidenceIDs: evidence)
        }
        guard !assertions.isEmpty else { return [] }
        let text = assertions.compactMap { assertion in
            guard let metric = metricByKey[assertion.metricKey] else { return nil }
            return Self.readableMetricText(metric)
        }.joined(separator: "；")
        return [HoloAgentClaim(id: "fallback-\(result.toolRequestID)-health", type: "observation",
                               displayText: text, metricAssertions: assertions,
                               evidenceIDs: assertions.flatMap(\.evidenceIDs),
                               prohibitedInferences: ["不要做医疗诊断"], confidence: 0.75)]
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
        if metric.metricKey.hasPrefix("dynamic."), let event {
            return event.excerpt
        }
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

    private static func readableMetricText(_ metric: HoloMetric) -> String? {
        guard var text = HoloMetricSemanticCatalog.sentence(
            metricKey: metric.metricKey,
            value: metric.value,
            unit: metric.unit,
            comparison: metric.comparison
        ) else { return nil }
        if let baselineValue = metric.baselineValue {
            let baseline = HoloMetricSemanticCatalog.formattedNumber(
                baselineValue,
                metricKey: metric.metricKey,
                unit: metric.unit
            )
            text += "，上期 \(baseline)\(metric.unit ?? "")"
        }
        return text
    }

    private static func shouldSuppressSuggestions(for question: String?) -> Bool {
        guard let question else { return false }
        let suggestionKeywords = ["建议", "怎么办", "怎么改善", "如何改善", "怎么做", "下一步"]
        return !suggestionKeywords.contains { question.contains($0) }
    }

    private static func deduplicatedClaims(_ claims: [HoloAgentClaim]) -> [HoloAgentClaim] {
        var coveredMetricKeys = Set<String>()
        var seenText = Set<String>()
        var result: [HoloAgentClaim] = []

        for claim in claims {
            var deduplicated = claim
            deduplicated.metricAssertions = claim.metricAssertions.filter {
                coveredMetricKeys.insert($0.metricKey).inserted
            }
            let normalized = claim.displayText.lowercased().filter { !$0.isWhitespace }
            guard !seenText.contains(normalized),
                  !deduplicated.metricAssertions.isEmpty || claim.metricAssertions.isEmpty else {
                continue
            }
            seenText.insert(normalized)
            deduplicated.evidenceIDs = Array(Set(deduplicated.metricAssertions.flatMap(\.evidenceIDs) + claim.evidenceIDs))
            result.append(deduplicated)
        }
        return result
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
    /// §6.2：执行代次已过期（被新执行取代），拒绝写回
    case staleExecution(jobID: String, generation: Int)

    var errorDescription: String? {
        switch self {
        case .jobNotFound(let id): return "找不到 Agent 任务：\(id)"
        case .checkpointMissing(let id): return "找不到任务的可恢复快照：\(id)"
        case .unknownStep(let step): return "mock 序列未覆盖步骤：\(step.rawValue)"
        case .loopNotConfigured: return "Agent Loop 未配置 LLM client 或 tool executor"
        case .staleExecution(let id, let generation): return "执行代次已过期，拒绝写回：job=\(id) generation=\(generation)"
        }
    }
}
