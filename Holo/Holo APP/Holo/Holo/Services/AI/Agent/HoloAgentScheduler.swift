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
                           now: Date = Date()) async throws -> Int {
        // 闭合 N1：扫描全部非终态 job（含 running 孤儿），逐个真正拉起 runLoop 到达终态。
        // 与现状 resumeUnfinishedJobs 的根本区别——这里真正重启推理，而非仅标记状态。
        let jobIDs = await runtime.collectResumableJobIDs(now: now)
        for jobID in jobIDs {
            _ = try? await runtime.runLoop(
                jobID: jobID, systemTemplate: systemTemplate, toolDescriptions: toolDescriptions, now: now
            )
        }
        return jobIDs.count
    }
}

extension HoloAgentScheduler {
    /// 全 App 共享的生产 Agent 调度器，绑定 shared runtime。
    /// @MainActor：装配需访问 @MainActor 的 HoloLocalAgentRuntime.shared。
    @MainActor
    static let shared = HoloAgentScheduler(runtime: HoloLocalAgentRuntime.shared)
}
