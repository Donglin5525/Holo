//
//  HoloAgentExecutionLease.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 5（§6.3）
//  执行租约协议：Lease 只表示「现在能否执行」，Lease 失效不等于 Job 失败。
//  Job 是持久化事实；Scheduler 是唯一执行权所有者，按场景为 job 分配合适的租约实现。
//

import Foundation

/// 执行租约类型（§6.3）。
nonisolated enum HoloAgentExecutionLeaseKind: String, Codable, Sendable {
    /// App 活跃时正常执行
    case foreground
    /// iOS 17–25 / fallback：beginBackgroundTask 短时续跑和安全取消
    case legacyBackground
    /// iOS 26 用户主动任务持续后台执行
    case continuedProcessing
}

/// Agent 进度快照（§9.4 雏形）：系统 UI 与 App 内状态读取同一份。
/// 只含非敏感技术字段（不得出现用户问题、健康指标、金额等）。
nonisolated struct HoloAgentProgressSnapshot: Equatable, Sendable {
    var jobID: String
    var state: HoloAgentJobState
    /// 预算总单位：maxLLMRounds + maxToolBatches（§9.4）
    var totalUnitCount: Int
    /// 已消耗单位：consumedLLMRounds + consumedToolBatches
    var completedUnitCount: Int
    /// 执行代次（诊断）
    var generation: Int

    init(jobID: String, state: HoloAgentJobState,
         totalUnitCount: Int, completedUnitCount: Int, generation: Int) {
        self.jobID = jobID
        self.state = state
        self.totalUnitCount = totalUnitCount
        self.completedUnitCount = completedUnitCount
        self.generation = generation
    }

    /// 从 job 构造（预算单位换算见 §9.4）。
    init(job: HoloAgentJob) {
        self.init(
            jobID: job.id,
            state: job.state,
            totalUnitCount: job.budget.maxLLMRounds + job.budget.maxToolBatches,
            completedUnitCount: job.budget.consumedLLMRounds + job.budget.consumedToolBatches,
            generation: job.executionGeneration ?? 0
        )
    }
}

/// 执行租约协议（§6.3）。
/// 实现必须：job 提前完成时立即 `finish` 释放（不等待场景回前台或系统 expiration）；
/// expiration 只做取消信号与尽快释放，不承担 checkpoint 保存（§6.4）。
nonisolated protocol HoloAgentExecutionLease: Sendable {
    /// 租约类型是不可变技术元数据，Scheduler 可跨 actor 同步读取。
    nonisolated var kind: HoloAgentExecutionLeaseKind { get }
    /// 上报进度（每次 checkpoint 后一次，避免高频刷新；legacy 实现无系统 UI 可为空操作）
    @MainActor
    func report(_ progress: HoloAgentProgressSnapshot) async
    /// 执行结束（job 终态或场景回收）：立即释放租约占用
    @MainActor
    func finish(success: Bool) async
}
