//
//  HoloAgentConsistencyReconciler.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 1（§5.4，修 P0-6 收尾）
//  启动一致性修复器：Job / Result / Checkpoint / Evidence 跨文件保存，不具备事务，
//  崩溃可能留下半完成状态。App 启动时（resume 之前）跑一次对齐，失败只记录不阻塞启动。
//

import Foundation

/// 一致性修复报告：各类修复计数，便于测试断言与启动日志。
struct HoloAgentReconcileReport: Equatable, Sendable {
    /// Result 已存在但 Job 非终态 → 补成 completed 的 job 数
    var jobsCompletedByResult: Int = 0
    /// Job completed 但 Result 缺失 → 置 failed（needs-finalization）的 job 数
    var jobsFailedMissingResult: Int = 0
    /// Checkpoint 引用 evidence 缺失 → 置 failed 的 job 数
    var jobsFailedMissingEvidence: Int = 0
    /// 同 job 历史多 Result（旧数据）收敛删除的 result 数
    var resultsConverged: Int = 0

    /// 是否发生任何修复
    var hasFixes: Bool {
        jobsCompletedByResult + jobsFailedMissingResult + jobsFailedMissingEvidence + resultsConverged > 0
    }
}

/// 启动一致性修复器（§5.4）。
/// 规则：
/// - Result 存在、Job 非终态 → job 补成 completed；
/// - Job completed、Result 缺失 → 置 failed 并写 errorSummary，不展示伪完成；
/// - 非终态 Job 的 checkpoint 引用 evidence 缺失 → 置 failed，不得继续生成无证据结论；
/// - 同 job 历史多 Result → 保留 generatedAt 最新一条，其余删除，store 收敛为每 job 一条。
actor HoloAgentConsistencyReconciler {

    private let persistence: HoloAgentPersistenceManager
    private let jobStore: HoloAgentJobStore
    private let checkpointStore: HoloAgentCheckpointStore
    private let resultStore: HoloAgentResultStore

    init(persistence: HoloAgentPersistenceManager) {
        self.persistence = persistence
        self.jobStore = persistence.jobStore
        self.checkpointStore = persistence.checkpointStore
        self.resultStore = persistence.resultStore
    }

    /// 终态集合（与 Runtime 对齐，避免反向依赖）。
    private static let terminalStates: Set<HoloAgentJobState> = [.completed, .failed, .cancelled, .superseded]

    /// 执行一次全量对齐。读取失败上抛（§5.5：不得当空库继续写）。
    @discardableResult
    func reconcile(now: Date = Date()) async throws -> HoloAgentReconcileReport {
        var report = HoloAgentReconcileReport()
        let jobs = try await jobStore.load()
        let allResults = try await resultStore.all()

        // 1. 同 job 历史多 Result（旧数据）→ 保留 generatedAt 最新，其余删除
        var latestResultByJob: [String: HoloAgentResult] = [:]
        var duplicateResultIDs: [String] = []
        for (jobID, group) in Dictionary(grouping: allResults, by: \.jobID) {
            let sorted = group.sorted { $0.generatedAt < $1.generatedAt }
            if let latest = sorted.last {
                latestResultByJob[jobID] = latest
            }
            if group.count > 1 {
                duplicateResultIDs.append(contentsOf: sorted.dropLast().map(\.id))
            }
        }
        if !duplicateResultIDs.isEmpty {
            try await resultStore.deleteByIDs(duplicateResultIDs)
            report.resultsConverged = duplicateResultIDs.count
        }

        for job in jobs {
            let result = latestResultByJob[job.id]
            // 2. Result 存在、Job 非终态 → job 补成 completed
            if let result, !Self.terminalStates.contains(job.state) {
                var fixed = job
                fixed.state = .completed
                fixed.resultID = result.id
                fixed.errorSummary = nil
                fixed.updatedAt = now
                try await jobStore.upsert(fixed)
                report.jobsCompletedByResult += 1
                continue
            }
            // 3. Job completed、Result 缺失 → 置 failed（needs-finalization），不展示伪完成
            if job.state == .completed, result == nil {
                var fixed = job
                fixed.state = .failed
                fixed.errorSummary = "任务曾标记完成但最终结果缺失，已转为失败，请重新发起分析"
                fixed.updatedAt = now
                try await jobStore.upsert(fixed)
                report.jobsFailedMissingResult += 1
                continue
            }
            // 4. 非终态 Job 的 checkpoint 引用 evidence 缺失 → 置 failed，不得继续生成无证据结论
            if !Self.terminalStates.contains(job.state),
               let checkpoint = try await checkpointStore.latestForJob(jobID: job.id),
               !checkpoint.evidenceRecordIDs.isEmpty {
                let evidenceIntact = try await persistence.validateCheckpoint(checkpoint)
                if !evidenceIntact {
                    var fixed = job
                    fixed.state = .failed
                    fixed.errorSummary = "任务快照引用的证据缺失，无法继续生成可信结论，请重新发起分析"
                    fixed.updatedAt = now
                    try await jobStore.upsert(fixed)
                    report.jobsFailedMissingEvidence += 1
                }
            }
        }
        return report
    }
}
