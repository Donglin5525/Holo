//
//  HoloAgentJobStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.3 Agent Job 仓库（upsert / 状态更新 / retention 清理）
//

import Foundation

/// JobStore 错误（§6.1 generation CAS）。
enum HoloAgentJobStoreError: Error, Equatable {
    /// acquire generation 时 job 不存在
    case jobNotFound(String)
}

/// 管理 `HoloAgentJob` 的持久化；所有写操作走 `HoloAgentJSONStore.mutate` 保证原子。
actor HoloAgentJobStore {

    private let store: HoloAgentJSONStore<HoloAgentJob>

    init() {
        self.store = HoloAgentJSONStore(fileName: "agentJobs.json")
    }

    /// 测试隔离用：写入指定目录，不污染真实 Application Support。
    init(directory: URL) {
        self.store = HoloAgentJSONStore(fileName: "agentJobs.json", directory: directory)
    }

    /// 插入或替换（按 id）。
    func upsert(_ job: HoloAgentJob) async throws {
        try await store.mutate { all in
            if let index = all.firstIndex(where: { $0.id == job.id }) {
                all[index] = job
            } else {
                all.append(job)
            }
        }
    }

    /// 读取全部 job。§5.5：读失败上抛，调用方不得当空库继续。
    func load() async throws -> [HoloAgentJob] {
        try await store.load()
    }

    /// 原子递增 job 的 executionGeneration 并返回新值（§6.1：load→+1→save 在 actor 内原子完成）。
    /// 旧数据 generation 为 nil 时视为 0，首次 acquire 返回 1。
    @discardableResult
    func acquireExecutionGeneration(jobID: String, now: Date = Date()) async throws -> Int {
        try await store.mutate { all -> Int in
            guard let index = all.firstIndex(where: { $0.id == jobID }) else {
                throw HoloAgentJobStoreError.jobNotFound(jobID)
            }
            let next = (all[index].executionGeneration ?? 0) + 1
            all[index].executionGeneration = next
            all[index].updatedAt = now
            return next
        }
    }

    /// CAS 读校验：job 当前 generation 是否仍等于给定值（§6.2 runLoop 写盘前调用）。
    /// job 不存在返回 false（已被清理，不得再写回）。
    func validateExecutionGeneration(jobID: String, generation: Int) async throws -> Bool {
        let all = try await store.load()
        guard let job = all.first(where: { $0.id == jobID }) else { return false }
        return (job.executionGeneration ?? 0) == generation
    }

    /// 按 jobID 更新状态与时间；未找到返回 false。
    @discardableResult
    func updateState(jobID: String, to state: HoloAgentJobState, now: Date = Date()) async throws -> Bool {
        try await store.mutate { all -> Bool in
            guard let index = all.firstIndex(where: { $0.id == jobID }) else { return false }
            all[index].state = state
            all[index].updatedAt = now
            return true
        }
    }

    /// 清理终态且超过保留期的 job，返回被清理的 jobIDs
    ///（供 Persistence Manager 级联清理 checkpoint / result）。
    @discardableResult
    func cleanup(policy: HoloJobCleanupPolicy, now: Date = Date()) async throws -> [String] {
        try await store.mutate { all -> [String] in
            var removed: [String] = []
            var kept: [HoloAgentJob] = []
            for job in all {
                if let days = Self.retentionDays(for: job.state, policy: policy),
                   now.timeIntervalSince(job.updatedAt) > TimeInterval(days * 86_400) {
                    removed.append(job.id)
                    continue
                }
                kept.append(job)
            }
            all = kept
            return removed
        }
    }

    /// 终态 job 的保留天数；非终态返回 nil（不清理）。superseded 按失败类终态回收。
    private static func retentionDays(for state: HoloAgentJobState, policy: HoloJobCleanupPolicy) -> Int? {
        switch state {
        case .completed:
            return policy.completedRetentionDays
        case .failed, .cancelled, .superseded:
            return policy.failedRetentionDays
        default:
            return nil
        }
    }
}
