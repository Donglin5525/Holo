//
//  HoloAgentScheduler.swift
//  Holo
//
//  HoloAI Agent V3.2 — Phase 1：全局可恢复调度器
//  接管所有 Agent 运行 Task。第一职责：App 被杀重启后，真正重启未完成 job 的 runLoop，
//  闭合现状 resume「仅标记状态、不重启推理」的恢复链断点（N1）。
//  设计为 actor（非 MainActor），避免 LLM 多轮推进绑死主线程。
//  生产经 HoloAIFeatureFlags.agentRuntimeEnabled 门控，关闭时零副作用。
//
//  Holo Agent 稳定执行 — Phase 2（§6.1，修 P0-2）：唯一执行权
//  - activeTasks[jobID]：同一 jobID 任意时刻最多一个执行 Task（runOrAttach）
//  - 新执行先在 JobStore 原子递增 executionGeneration（CAS），runLoop 写盘前校验
//  - P0 用户任务并发上限 1；P3/P4 不与 P0 抢占（跳过并落盘原因）
//

import Foundation
import os.log

actor HoloAgentScheduler {

    private let runtime: HoloLocalAgentRuntime
    /// 后台任务 client（可注入 fake；nil 时首次用到才惰性创建生产实现，避免非 MainActor 上下文构造）
    private var backgroundTaskClient: (any HoloBackgroundTaskClient)?
    /// iOS 26 持续处理 client（可注入 fake；nil 时按系统版本惰性解析）
    private var continuedClient: (any HoloContinuedProcessingClient)?
    /// Phase 7 无敏感结构化事件；测试默认 no-op，生产 shared 显式注入持久化仓库。
    private let eventRecorder: any HoloAgentEventRecording
    private let logger = Logger(subsystem: "com.holo.app", category: "AgentScheduler")

    /// 执行注册表（§6.1）：jobID → 执行 Task。同一 jobID 任意时刻最多一个。
    private var activeTasks: [String: Task<HoloAgentJob, Error>] = [:]
    /// 登记令牌：Task 完成回调只清理同一次登记（Task 值类型不可比较，用 UUID 区分）。
    private var activeTaskTokens: [String: UUID] = [:]
    /// 活跃执行的 trigger：并发门控（P0 上限 1 / P3/P4 不抢占）用。
    private var activeTriggers: [String: HoloAgentTrigger] = [:]

    /// 租约注册表（§6.3）：jobID → 当前租约（foreground/legacyBackground）。
    /// scene-sweep 兜底租约也登记在此（约定 ID，不对应真实 job）。
    private var activeLeases: [String: any HoloAgentExecutionLease] = [:]
    /// 后台期间是否有租约被系统 expiration（回前台时决定是否走恢复链）。
    private var didExpireInBackground = false

    /// 场景兜底租约的约定 jobID：无活跃执行时申请，仅用于系统到期时的孤儿扫描。
    private static let sceneSweepLeaseID = "scene-sweep"

    private var jobStore: HoloAgentJobStore { runtime.jobStore }

    /// 终态集合：与 Runtime 对齐（终态 job 不再启动新执行）。
    private static let terminalStates: Set<HoloAgentJobState> = [.completed, .failed, .cancelled, .superseded]

    init(runtime: HoloLocalAgentRuntime,
         backgroundTaskClient: (any HoloBackgroundTaskClient)? = nil,
         continuedClient: (any HoloContinuedProcessingClient)? = nil,
         eventRecorder: any HoloAgentEventRecording = HoloNoopAgentEventRecorder.shared) {
        self.runtime = runtime
        self.backgroundTaskClient = backgroundTaskClient
        self.continuedClient = continuedClient
        self.eventRecorder = eventRecorder
    }

    /// 后台任务 client（@MainActor）：注入值优先；未注入时首次用到才在 MainActor 创建生产实现。
    private func resolvedBackgroundTaskClient() async -> any HoloBackgroundTaskClient {
        if let backgroundTaskClient { return backgroundTaskClient }
        let created = await MainActor.run { UIApplicationBackgroundTaskClient() }
        backgroundTaskClient = created
        return created
    }

    /// iOS 26 持续处理 client（§9）：注入值优先（测试 fake）；否则 iOS 26+ 用生产实现，低版本 nil。
    private func resolvedContinuedClient() async -> (any HoloContinuedProcessingClient)? {
        if let continuedClient { return continuedClient }
        if #available(iOS 26.0, *) {
            let created = await MainActor.run { HoloSystemContinuedProcessingClient() }
            continuedClient = created
            return created
        }
        return nil
    }

    /// §9.1 continued 资格判断：iOS 26+ / 用户明确发起（userQuestion）/ 已同意 AI 数据处理 /
    /// 无其他 P0 持有 continued 执行权 / 开关开启。Observer/定时/自动任务被 trigger 门槛天然排除。
    private func continuedEligibility(for job: HoloAgentJob) async -> Bool {
        HoloAgentContinuedEligibility.isEligible(
            trigger: job.trigger,
            clientAvailable: await resolvedContinuedClient() != nil,
            consentGranted: HoloAIFeatureFlags.aiDataProcessingConsentGranted,
            flagEnabled: HoloAIFeatureFlags.agentContinuedProcessingEnabled,
            hasActiveContinuedLease: activeLeases.values.contains { $0.kind == .continuedProcessing }
        )
    }

    // MARK: - §6.1 对外接口

    /// 创建一个新对话深度分析 job 并经 runOrAttach 跑完 runLoop（Chat/Observer 入口统一走此）。
    func createAndRun(_ request: HoloAgentStartRequest) async throws -> HoloAgentJob {
        let job = try await runtime.startAnalysisJob(
            question: request.question,
            trigger: request.trigger,
            sourceMessageID: request.sourceMessageID,
            now: request.now
        )
        return try await runOrAttach(
            jobID: job.id,
            reason: request.trigger == .userQuestion ? .userInitiated : .automaticInitiated,
            systemTemplate: request.systemTemplate,
            toolDescriptions: request.toolDescriptions,
            now: request.now
        )
    }

    /// 同一 jobID 唯一执行：已有活跃 Task → attach 等待其结果（不创建第二份）；
    /// 无 → 并发门控 → acquire generation → 启动新 runLoop Task 并登记。
    /// 登记与最后一次复查之间无 await，保证并发调用只产生一个执行 Task（actor 可重入安全）。
    @discardableResult
    func runOrAttach(jobID: String, reason: HoloAgentResumeReason,
                     systemTemplate: String = "", toolDescriptions: String = "",
                     now: Date = Date()) async throws -> HoloAgentJob {
        if let existing = activeTasks[jobID] {
            logger.log("[Agent] attach 已有执行 jobID=\(jobID, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            var event = HoloAgentTelemetryEvent(
                name: .executionAttached,
                leaseKind: activeLeases[jobID]?.kind
            )
            event.jobID = jobID
            await eventRecorder.record(event)
            return try await existing.value
        }
        guard let job = try await jobStore.load().first(where: { $0.id == jobID }) else {
            throw HoloAgentRuntimeError.jobNotFound(jobID)
        }
        // 终态 job 不启动新执行，直接返回现状（cancel 后 attach 语义）
        guard !Self.terminalStates.contains(job.state) else { return job }
        // load 后复查：期间可能有别的调用已登记
        if let existing = activeTasks[jobID] {
            var event = HoloAgentTelemetryEvent(
                name: .executionAttached,
                leaseKind: activeLeases[jobID]?.kind
            )
            event.jobID = jobID
            await eventRecorder.record(event)
            return try await existing.value
        }

        // 并发门控（§2.2/§6.1）：P0 用户任务上限 1；P3/P4 不与 P0 抢占
        if job.trigger == .userQuestion {
            for (otherID, trigger) in activeTriggers where trigger == .userQuestion && otherID != jobID {
                logger.log("[Agent] 新 P0 抢占旧 P0，取消旧执行 jobID=\(otherID, privacy: .public)")
                await cancel(jobID: otherID, source: .superseded, now: now)
            }
        } else if activeTriggers.values.contains(.userQuestion) {
            logger.log("[Agent] P0 活跃中，跳过低优先级任务 jobID=\(jobID, privacy: .public) trigger=\(job.trigger.rawValue, privacy: .public)")
            try await runtime.recordExecutionSkip(
                jobID: jobID,
                reason: "有用户任务正在执行，低优先级任务暂不启动，等待下轮恢复",
                now: now
            )
            return job
        }
        // 门控中的 await 后最终复查；之后同步登记（无 await），保证唯一执行
        if let existing = activeTasks[jobID] {
            return try await existing.value
        }

        let token = UUID()
        let jobStore = self.jobStore
        let task = Task { [runtime, jobStore, weak self] in
            // 新执行先在 JobStore 原子递增 executionGeneration，拿到代次才进入 runLoop（§6.1）
            let generation = try await jobStore.acquireExecutionGeneration(jobID: jobID, now: now)
            await self?.recordExecutionEvent(
                .executionAcquired,
                job: job,
                generation: generation,
                leaseKind: .foreground,
                timestamp: now
            )
            // §5.2：落盘最近一次恢复/启动原因（诊断字段；只有真正启动的执行才写）
            try await runtime.recordResumeReason(jobID: jobID, reason: reason, now: now)
            if reason != .userInitiated {
                await self?.recordExecutionEvent(
                    .resumeStarted,
                    job: job,
                    generation: generation,
                    leaseKind: .foreground,
                    timestamp: now
                )
            }
            // §9：在唯一执行 Task 内尝试接管 continued（避免并发入口重复提交；同 job 仍只有一个执行，
            // continued 只是租约层）。不接纳→保持 foreground，切后台回落 legacy（§9.3 .fail）
            var reporter: (@Sendable (HoloAgentProgressSnapshot) async -> Void)?
            if let (lease, leaseReporter) = await self?.acquireContinuedLeaseIfEligible(
                job: job,
                executionToken: token
            ) {
                await self?.adoptContinuedLease(jobID: jobID, lease: lease)
                reporter = leaseReporter
            }
            return try await runtime.runLoop(
                jobID: jobID, generation: generation,
                systemTemplate: systemTemplate, toolDescriptions: toolDescriptions,
                progressReporter: reporter, now: now
            )
        }
        activeTasks[jobID] = task
        activeTaskTokens[jobID] = token
        activeTriggers[jobID] = job.trigger
        // §6.3：新执行默认持前台租约；continued 接管成功/切后台时在执行 Task/场景事件里换绑
        activeLeases[jobID] = HoloAgentForegroundLease()
        // 统一清理：Task 完成/失败/取消后从注册表移除（只清同一次登记），并立即释放租约（§6.3）。
        // 注意：旧 token 的完成回调不得结束同 job 后续代次的新租约。
        Task { [weak self] in
            let result = await task.result
            let succeeded = (try? result.get())?.state == .completed
            await self?.finalizeActiveTask(jobID: jobID, token: token, success: succeeded)
        }
        logger.log("[Agent] 启动新执行 jobID=\(jobID, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        do {
            let result = try await task.value
            await finalizeActiveTask(jobID: jobID, token: token, success: result.state == .completed)
            return result
        } catch {
            await finalizeActiveTask(jobID: jobID, token: token, success: false)
            throw error
        }
    }

    /// 取消执行：取消活跃 Task（取消信号）+ 落终态；注册表立即让位。
    /// source 区分用户取消、系统取消与被新任务抢占（§2.1-8：不混为一谈）；
    /// §5.2：被抢占（.superseded）落 superseded 终态，其余落 cancelled。
    func cancel(jobID: String, source: HoloAgentCancellationSource, now: Date = Date()) async {
        if let task = activeTasks[jobID] {
            task.cancel()
            removeActiveTaskRegistration(jobID: jobID)
        }
        await finishLease(jobID: jobID, success: false)
        do {
            if source == .superseded {
                _ = try await runtime.supersedeJob(jobID: jobID, now: now)
            } else {
                _ = try await runtime.cancel(jobID: jobID, now: now)
            }
            if let job = try await jobStore.load().first(where: { $0.id == jobID }) {
                await eventRecorder.record(HoloAgentTelemetryEvent(
                    name: .jobCancelled,
                    timestamp: now,
                    job: job,
                    errorCode: source.rawValue
                ))
            }
            logger.log("[Agent] 已取消 jobID=\(jobID, privacy: .public) source=\(source.rawValue, privacy: .public)")
        } catch {
            logger.error("[Agent] 取消落盘失败 jobID=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// 暂停执行：取消活跃 Task（§6.4 只发取消信号 + 状态标记，不承担 checkpoint 保存——
    /// 正常推进中已持续落盘）+ 标记 waitingForForeground；注册表立即让位，
    /// 后续 runOrAttach 以新 generation 接管，旧 Task 晚返回的写回会被 stale guard 拒绝。
    func pause(jobID: String, reason: HoloAgentPauseReason, now: Date = Date()) async {
        if let task = activeTasks[jobID] {
            task.cancel()
            removeActiveTaskRegistration(jobID: jobID)
            logger.log("[Agent] 暂停执行 jobID=\(jobID, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        }
        await finishLease(jobID: jobID, success: false)
        do {
            _ = try await runtime.pauseJob(jobID: jobID, now: now)
        } catch {
            logger.error("[Agent] 暂停标记失败 jobID=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// 系统后台时间到期（lease expiration）：取消所有活跃执行并标记 waitingForForeground。
    /// 兜底把落盘为运行态但无活跃 Task 的 job（旧数据/异常路径）一并标记。
    func pauseForBackgroundExpiration(now: Date = Date()) async {
        for jobID in Array(activeTasks.keys) {
            await pause(jobID: jobID, reason: .backgroundTimeExpired, now: now)
        }
        do {
            try await runtime.pauseForBackground(now: now)
        } catch {
            logger.error("[Agent] 后台到期批量标记失败 error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - §6.3 场景 × 租约协调

    /// App 进入后台：为每个活跃 job 申请绑定 jobID 的 legacy 租约（§9.6：租约绑定活跃 Job）。
    /// 已被系统接管的 continued job 不回落 legacy（§9.3）；无活跃执行时申请 scene-sweep 兜底租约。
    func sceneDidEnterBackground(now: Date = Date()) async {
        let activeJobIDs = Array(activeTasks.keys)
        guard !activeJobIDs.isEmpty else {
            await attachLegacyLease(jobID: Self.sceneSweepLeaseID, now: now)
            return
        }
        var legacyCount = 0
        for jobID in activeJobIDs {
            if activeLeases[jobID]?.kind == .continuedProcessing { continue }
            await attachLegacyLease(jobID: jobID, now: now)
            legacyCount += 1
        }
        logger.log("[Agent] 进入后台：已为 \(legacyCount, privacy: .public) 个活跃 job 申请 legacy 租约")
    }

    /// App 回前台：释放全部 legacy 租约（后台时间归还系统），仍在执行的任务换回前台租约。
    /// - Returns: 后台期间是否有租约被系统 expiration（决定 manager 走恢复链还是只同步状态）。
    @discardableResult
    func sceneWillEnterForeground(now: Date = Date()) async -> Bool {
        let expired = didExpireInBackground
        didExpireInBackground = false
        // 先快照再逐个释放（遍历中不原地修改字典）
        let legacyEntries = activeLeases.filter { $0.value.kind == .legacyBackground }
        for (jobID, lease) in legacyEntries {
            // 正常释放（非 expiration）：后台时间立即归还；job 未结束，前台继续执行
            await lease.finish(success: true)
            if jobID == Self.sceneSweepLeaseID {
                activeLeases[jobID] = nil
            } else if activeTasks[jobID] != nil {
                activeLeases[jobID] = HoloAgentForegroundLease()
                var event = HoloAgentTelemetryEvent(
                    name: .leaseChanged,
                    timestamp: now,
                    leaseKind: .foreground
                )
                event.jobID = jobID
                await eventRecorder.record(event)
            } else {
                activeLeases[jobID] = nil
            }
        }
        return expired
    }

    /// 申请绑定 jobID 的 legacy 租约（已是 legacy 不重复申请）。
    /// expiration 回调统一走 leaseDidExpire（取消 Task + 状态标记 + 孤儿扫描）。
    private func attachLegacyLease(jobID: String, now: Date) async {
        if activeLeases[jobID]?.kind == .legacyBackground { return }
        let lease = await HoloAgentLegacyBackgroundLease(
            jobID: jobID,
            client: resolvedBackgroundTaskClient(),
            onExpiration: { [weak self] expiredJobID in
                Task { await self?.leaseDidExpire(jobID: expiredJobID) }
            }
        )
        // 竞态兜底：申请期间 job 已完成的租约立即释放，不滞留
        if jobID == Self.sceneSweepLeaseID || activeTasks[jobID] != nil {
            activeLeases[jobID] = lease
            var event = HoloAgentTelemetryEvent(
                name: .leaseChanged,
                timestamp: now,
                leaseKind: .legacyBackground
            )
            event.jobID = jobID == Self.sceneSweepLeaseID ? nil : jobID
            await eventRecorder.record(event)
        } else {
            await lease.finish(success: false)
        }
    }

    /// §6.4 lease expiration：取消对应 Task（pause 语义落 waitingForForeground+backgroundTimeExpired），
    /// 并做孤儿扫描兜底；租约自身已在 handler 内释放，此处只清登记。
    private func leaseDidExpire(jobID: String) async {
        didExpireInBackground = true
        activeLeases[jobID] = nil
        var event = HoloAgentTelemetryEvent(
            name: .executionExpired,
            leaseKind: .legacyBackground,
            errorCode: "BACKGROUND_TIME_EXPIRED"
        )
        event.jobID = jobID == Self.sceneSweepLeaseID ? nil : jobID
        await eventRecorder.record(event)
        if jobID != Self.sceneSweepLeaseID {
            await pause(jobID: jobID, reason: .backgroundTimeExpired)
        }
        // 孤儿兜底：磁盘 running 状态但无活跃 Task 的 job 一并标记
        do {
            try await runtime.pauseForBackground()
        } catch {
            logger.error("[Agent] 租约到期孤儿扫描失败 error=\(String(describing: error), privacy: .public)")
        }
    }

    /// §9.5 系统结束 continued task（expiration/取消，按「不可区分」保守路径）：
    /// 结束本次 execution lease，job 进 paused 并记录来源（waitReason=.systemCapacity），
    /// 不自动悄悄复活（paused 不参与 resumeEligibleJobs）；用户回前台由恢复链/明确动作接管。
    private func continuedLeaseDidEnd(jobID: String, executionToken: UUID) async {
        // expiration 回调跨 MainActor → Scheduler actor 异步投递；若期间同一 job 已由
        // 新 generation 接管，旧 lease 绝不能清掉或取消新执行。
        guard activeTaskTokens[jobID] == executionToken else {
            logger.log("[Agent] 忽略旧 continued lease 的结束回调 jobID=\(jobID, privacy: .public)")
            return
        }
        activeLeases[jobID] = nil
        var event = HoloAgentTelemetryEvent(
            name: .executionExpired,
            leaseKind: .continuedProcessing,
            errorCode: "SYSTEM_CAPACITY"
        )
        event.jobID = jobID
        await eventRecorder.record(event)
        if let task = activeTasks[jobID] {
            task.cancel()
            removeActiveTaskRegistration(jobID: jobID)
        }
        do {
            _ = try await runtime.suspendJob(
                jobID: jobID,
                reason: "系统结束了持续后台执行，回到 App 后可以手动继续",
                now: Date()
            )
            logger.log("[Agent] continued 执行权被系统结束，job 已暂停待手动继续 jobID=\(jobID, privacy: .public)")
        } catch {
            logger.error("[Agent] continued 结束落盘失败 jobID=\(jobID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// §9：执行 Task 内调用——资格满足时接管 continued 执行权（.fail）并返回租约与进度上报闭包。
    /// 在唯一执行 Task 内做 acquire，并发入口 attach 同一 Task，不会产生重复提交（§6.1/§9.3）。
    private func acquireContinuedLeaseIfEligible(
        job: HoloAgentJob,
        executionToken: UUID
    ) async -> (lease: any HoloAgentExecutionLease, reporter: @Sendable (HoloAgentProgressSnapshot) async -> Void)? {
        guard await continuedEligibility(for: job),
              let client = await resolvedContinuedClient() else { return nil }
        let continued = await HoloAgentContinuedProcessingLease(
            jobID: job.id,
            client: client,
            initialProgress: HoloAgentProgressSnapshot(job: job),
            onSystemEnded: { [weak self] endedJobID in
                Task {
                    await self?.continuedLeaseDidEnd(
                        jobID: endedJobID,
                        executionToken: executionToken
                    )
                }
            }
        )
        guard await continued.acquire() else {
            logger.log("[Agent] continued 未获接纳，保持前台/回落 legacy jobID=\(job.id, privacy: .public)")
            return nil
        }
        await recordExecutionEvent(
            .leaseChanged,
            job: job,
            generation: job.executionGeneration,
            leaseKind: .continuedProcessing
        )
        logger.log("[Agent] 已接管 continued 执行权 jobID=\(job.id, privacy: .public)")
        return (continued, { snapshot in
            await continued.report(snapshot)
        })
    }

    /// 换绑 continued 租约（仅当前执行 Task 内调用；该 job 此时必有前台租约在册）
    private func adoptContinuedLease(jobID: String, lease: any HoloAgentExecutionLease) {
        activeLeases[jobID] = lease
    }

    /// job 终态/取消/暂停：立即释放租约（§6.3：不等待场景回前台或系统 expiration）。
    private func finishLease(jobID: String, success: Bool) async {
        guard let lease = activeLeases.removeValue(forKey: jobID) else { return }
        await lease.finish(success: success)
    }

    /// 扫描非终态 job（含 running 孤儿/带旧 generation 的 orphan），按优先级限量恢复。
    /// 每个 job 走 runOrAttach（重新 acquire generation 后恢复，§6.4）；
    /// 跳过与失败写可解释状态/日志，不使用 `try?`（§十 Phase 2 任务 7）。
    @discardableResult
    func resumeEligibleJobs(trigger: HoloAgentResumeTrigger, systemTemplate: String = "",
                            toolDescriptions: String = "", now: Date = Date(),
                            maxResume: Int = 3) async throws -> Int {
        // 扫描非终态 job，按优先级排序，限量恢复（§9.5 避免批量恢复拖慢首屏）
        var jobs = try await runtime.collectResumableJobs(now: now)
        jobs.sort { priorityRank($0.trigger) < priorityRank($1.trigger) }
        let toResume = maxResume > 0 ? Array(jobs.prefix(maxResume)) : jobs
        var resumed = 0
        for job in toResume {
            guard !Task.isCancelled else { break }  // cancel 后停止批量恢复
            // §5.2：超过绝对截止的等待 job 不再恢复，置失败（防止无限等待）
            if job.isPastAbsoluteDeadline(at: now) {
                do {
                    _ = try await runtime.failJob(jobID: job.id, reason: "任务已超过截止时限，不再自动恢复", now: now)
                } catch {
                    logger.error("[Agent] 截止 job 置失败落盘失败 jobID=\(job.id, privacy: .public)")
                }
                continue
            }
            do {
                guard try await inputSnapshotMatches(job, now: now) else { continue }
                _ = try await runOrAttach(
                    jobID: job.id, reason: trigger.resumeReason,
                    systemTemplate: systemTemplate, toolDescriptions: toolDescriptions, now: now
                )
                resumed += 1
            } catch let error as HoloAgentRuntimeError {
                if case .staleExecution = error {
                    // 已被更新执行接管，不算失败
                    logger.log("[Agent] 恢复被新执行取代 jobID=\(job.id, privacy: .public)")
                } else {
                    logger.error("[Agent] 恢复 job 失败 jobID=\(job.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    await recordResumeFailure(jobID: job.id, error: error, now: now)
                }
            } catch is CancellationError {
                // 有意取消（pause/cancel），不算失败
                logger.log("[Agent] 恢复被取消 jobID=\(job.id, privacy: .public)")
            } catch {
                logger.error("[Agent] 恢复 job 失败 jobID=\(job.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                await recordResumeFailure(jobID: job.id, error: error, now: now)
            }
        }
        return resumed
    }

    // MARK: - 兼容包装（旧调用方平滑过渡）

    /// 兼容包装：等价 resumeEligibleJobs(trigger: .appLaunch)。
    @discardableResult
    func resumeAndContinue(systemTemplate: String, toolDescriptions: String,
                           now: Date = Date(), maxResume: Int = 3) async throws -> Int {
        try await resumeEligibleJobs(
            trigger: .appLaunch, systemTemplate: systemTemplate,
            toolDescriptions: toolDescriptions, now: now, maxResume: maxResume
        )
    }

    /// 兼容包装：等价 createAndRun(HoloAgentStartRequest)。
    func start(question: String, systemTemplate: String, toolDescriptions: String,
               sourceMessageID: UUID? = nil,
               now: Date = Date()) async throws -> HoloAgentJob {
        try await createAndRun(HoloAgentStartRequest(
            question: question,
            trigger: .userQuestion,
            systemTemplate: systemTemplate,
            toolDescriptions: toolDescriptions,
            sourceMessageID: sourceMessageID,
            now: now
        ))
    }

    /// 清理终态且超保留期的 job 及其关联 checkpoint/result（§9.6 体积治理）。
    @discardableResult
    func cleanupTerminalJobs(policy: HoloJobCleanupPolicy = HoloJobCleanupPolicy(),
                             now: Date = Date()) async throws -> [String] {
        try await runtime.cleanupTerminalJobs(policy: policy, now: now)
    }

    // MARK: - 内部

    /// 对比 job 输入 hash 与 checkpoint 记录（§5.1）：
    /// - 无 hash 或 legacy（旧 Swift `Hasher` 值，非 64 位 hex）→ 视为匹配，重建稳定 hash 写回 checkpoint；
    /// - 稳定 hash 且相等 → 恢复；
    /// - 稳定 hash 不等 → 输入已变化：落盘 mismatch 原因（needs-replan），跳过恢复。
    private func inputSnapshotMatches(_ job: HoloAgentJob, now: Date) async throws -> Bool {
        let currentHash = HoloAgentInputSnapshotHasher.hash(for: job)
        guard let checkpoint = try await runtime.latestCheckpointForJob(jobID: job.id) else { return true }
        guard let stored = checkpoint.inputSnapshotHash,
              HoloAgentInputSnapshotHasher.isStableHash(stored) else {
            // 旧 checkpoint（无 hash / legacy Hasher 值）：不得用于拒绝恢复，重建稳定 hash
            try await runtime.refreshStableInputSnapshotHash(jobID: job.id, hash: currentHash, now: now)
            return true
        }
        if stored == currentHash { return true }
        logger.warning("[Agent] inputSnapshotHash 不匹配，跳过恢复 jobID=\(job.id, privacy: .public)")
        try await runtime.recordInputSnapshotMismatch(jobID: job.id, now: now)
        return false
    }

    /// 恢复失败原因落盘（可解释状态）；落盘再失败只记日志。
    private func recordResumeFailure(jobID: String, error: Error, now: Date) async {
        do {
            try await runtime.recordExecutionSkip(
                jobID: jobID,
                reason: "恢复执行失败：\(String(describing: error))",
                now: now
            )
        } catch {
            logger.error("[Agent] 失败原因落盘也失败 jobID=\(jobID, privacy: .public)")
        }
    }

    /// 完成回调清理：只清同一次登记（token 相同），并只结束这一次执行绑定的租约。
    /// 这是系统取消后快速手动恢复的关键护栏：旧 Task 晚完成不得误结束新 continued lease。
    private func finalizeActiveTask(jobID: String, token: UUID, success: Bool) async {
        guard activeTaskTokens[jobID] == token else { return }
        if let job = try? await jobStore.load().first(where: { $0.id == jobID }) {
            let name: HoloAgentEventName? = switch job.state {
            case .completed: .jobCompleted
            case .failed: .jobFailed
            case .cancelled, .superseded: .jobCancelled
            default: nil
            }
            if let name {
                let duration = max(0, Int(job.updatedAt.timeIntervalSince(job.createdAt) * 1_000))
                await eventRecorder.record(HoloAgentTelemetryEvent(
                    name: name,
                    job: job,
                    leaseKind: activeLeases[jobID]?.kind,
                    durationMilliseconds: duration,
                    errorCode: success ? nil : Self.terminalErrorCode(for: job)
                ))
            }
        }
        removeActiveTaskRegistration(jobID: jobID)
        await finishLease(jobID: jobID, success: success)
    }

    /// Debug 导出只读取租约类型，不暴露系统 task 对象。
    func debugActiveLeaseKinds() -> [String: HoloAgentExecutionLeaseKind] {
        activeLeases.reduce(into: [:]) { result, entry in
            guard entry.key != Self.sceneSweepLeaseID else { return }
            result[entry.key] = entry.value.kind
        }
    }

    private func recordExecutionEvent(
        _ name: HoloAgentEventName,
        job: HoloAgentJob,
        generation: Int?,
        leaseKind: HoloAgentExecutionLeaseKind?,
        timestamp: Date = Date()
    ) async {
        await eventRecorder.record(HoloAgentTelemetryEvent(
            name: name,
            timestamp: timestamp,
            job: job,
            generation: generation,
            leaseKind: leaseKind
        ))
    }

    private nonisolated static func terminalErrorCode(for job: HoloAgentJob) -> String? {
        switch job.state {
        case .failed: return "AGENT_JOB_FAILED"
        case .cancelled: return "CANCELLED"
        case .superseded: return "SUPERSEDED"
        default: return nil
        }
    }

    private func removeActiveTaskRegistration(jobID: String) {
        activeTasks[jobID] = nil
        activeTaskTokens[jobID] = nil
        activeTriggers[jobID] = nil
    }

    /// trigger 优先级：P0 用户对话 > P1 刷新 > P2/P3 Observer > 其余。
    private nonisolated func priorityRank(_ trigger: HoloAgentTrigger) -> Int {
        switch trigger {
        case .userQuestion: return 0
        case .memoryGalleryRefresh: return 1
        case .observerTier2: return 2
        default: return 3
        }
    }
}

extension HoloAgentScheduler {
    /// 全 App 共享的生产 Agent 调度器，绑定 shared runtime。
    /// @MainActor：装配需访问 @MainActor 的 HoloLocalAgentRuntime.shared。
    @MainActor
    static let shared = HoloAgentScheduler(
        runtime: HoloLocalAgentRuntime.shared,
        eventRecorder: HoloAgentEventStore.shared
    )
}
