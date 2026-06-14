//
//  HoloAgentJobStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.3 Agent Job 仓库（upsert / 状态更新 / retention 清理）
//

import Foundation

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

    /// 读取全部 job。
    func load() async -> [HoloAgentJob] {
        await store.load()
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

    /// 终态 job 的保留天数；非终态返回 nil（不清理）。
    private static func retentionDays(for state: HoloAgentJobState, policy: HoloJobCleanupPolicy) -> Int? {
        switch state {
        case .completed:
            return policy.completedRetentionDays
        case .failed, .cancelled:
            return policy.failedRetentionDays
        default:
            return nil
        }
    }
}
