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

import Foundation

actor HoloAgentScheduler {

    private let runtime: HoloLocalAgentRuntime

    init(runtime: HoloLocalAgentRuntime) {
        self.runtime = runtime
    }

    /// 恢复所有未完成 job 并真正拉起 runLoop 到达终态（闭合 N1）。
    ///
    /// 非终态 job 含两类：
    /// - `waitingForForeground`：正常进后台被暂停，重启后需续跑；
    /// - `running` 孤儿：进程被系统硬杀，来不及 pauseForBackground，落盘仍是 running。
    ///
    /// 现状 `resumeUnfinishedJobs` 因 `where state != .running` 会排除 running 孤儿，
    /// 且 resume 后不重启 runLoop，导致永久晾死。本方法修复这两点。
    ///
    /// 调用方应在后台 Task 中调用（串行恢复多个 job 时），避免阻塞首屏。
    @discardableResult
    func resumeAndContinue(systemTemplate: String, toolDescriptions: String,
                           now: Date = Date(), maxResume: Int = 3) async throws -> Int {
        // 闭合 N1：扫描非终态 job，按优先级排序，限量恢复（§9.5 避免批量恢复拖慢首屏）。
        var jobs = await runtime.collectResumableJobs(now: now)
        jobs.sort { priorityRank($0.trigger) < priorityRank($1.trigger) }
        let toResume = maxResume > 0 ? Array(jobs.prefix(maxResume)) : jobs
        var resumed = 0
        for job in toResume {
            guard await inputSnapshotMatches(job) else { continue }
            _ = try? await runtime.runLoop(
                jobID: job.id, systemTemplate: systemTemplate, toolDescriptions: toolDescriptions, now: now
            )
            resumed += 1
        }
        return resumed
    }

    /// 对比 job 输入 hash 与 checkpoint 记录：相同才恢复，不同则跳过（用户改了问题/时间范围，需重新规划）。
    private func inputSnapshotMatches(_ job: HoloAgentJob) async -> Bool {
        let cp = await runtime.latestCheckpointForJob(jobID: job.id)
        guard let hash = cp?.inputSnapshotHash else { return true }  // 无 hash → 兼容旧 checkpoint
        return hash == computeInputSnapshotHash(for: job)
    }

    private nonisolated func computeInputSnapshotHash(for job: HoloAgentJob) -> String {
        var hasher = Hasher()
        hasher.combine(job.userQuestion)
        if let start = job.timeRange?.start { hasher.combine(start) }
        if let end = job.timeRange?.end { hasher.combine(end) }
        return String(hasher.finalize())
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

    /// 清理终态且超保留期的 job 及其关联 checkpoint/result（§9.6 体积治理）。
    @discardableResult
    func cleanupTerminalJobs(policy: HoloJobCleanupPolicy = HoloJobCleanupPolicy(),
                             now: Date = Date()) async throws -> [String] {
        try await runtime.cleanupTerminalJobs(policy: policy, now: now)
    }

    /// Phase 2：启动一个新对话深度分析 job 并跑完 runLoop，返回最终 job（供 AnalysisService 渲染）。
    /// Chat / Observer 入口经此统一由 Scheduler 接管；未来在此层加 Task 池跟踪、同类去重、取消。
    func start(question: String, systemTemplate: String, toolDescriptions: String,
               now: Date = Date()) async throws -> HoloAgentJob {
        let job = try await runtime.startAnalysisJob(question: question, now: now)
        return try await runtime.runLoop(
            jobID: job.id, systemTemplate: systemTemplate, toolDescriptions: toolDescriptions, now: now
        )
    }
}

extension HoloAgentScheduler {
    /// 全 App 共享的生产 Agent 调度器，绑定 shared runtime。
    /// @MainActor：装配需访问 @MainActor 的 HoloLocalAgentRuntime.shared。
    @MainActor
    static let shared = HoloAgentScheduler(runtime: HoloLocalAgentRuntime.shared)
}
