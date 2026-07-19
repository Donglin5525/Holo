//
//  HoloAgentResultStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.3 Agent Result 仓库（upsert / 按 job 查）
//

import Foundation

/// 管理 `HoloAgentResult` 的持久化。
actor HoloAgentResultStore {

    private let store: HoloAgentJSONStore<HoloAgentResult>

    init() {
        self.store = HoloAgentJSONStore(fileName: "agentResults.json")
    }

    init(directory: URL) {
        self.store = HoloAgentJSONStore(fileName: "agentResults.json", directory: directory)
    }

    /// 插入或替换（§5.4：按 jobID 唯一 —— 同一 job 只保留一条 canonical result，
    /// 替换而非累积，修复 P0-6 崩溃恢复产生多结果/读回旧结果）。
    func upsert(_ result: HoloAgentResult) async throws {
        try await store.mutate { all in
            if let index = all.firstIndex(where: { $0.jobID == result.jobID }) {
                all[index] = result
            } else {
                all.append(result)
            }
        }
    }

    /// 返回某 job 的 result（依赖 jobID 唯一约束；旧数据多结果请先经 Reconciler 收敛）。
    func forJob(jobID: String) async throws -> HoloAgentResult? {
        let all = try await store.load()
        return all.first { $0.jobID == jobID }
    }

    /// 返回最近一条 result（按 generatedAt 降序），供记忆长廊展示。
    func latest() async throws -> HoloAgentResult? {
        let all = try await store.load()
        return all.max(by: { $0.generatedAt < $1.generatedAt })
    }

    /// 读取全部 result（一致性修复收敛用）。
    func all() async throws -> [HoloAgentResult] {
        try await store.load()
    }

    /// 删除指定 result IDs（一致性修复收敛旧多结果用），返回删除条数。
    @discardableResult
    func deleteByIDs(_ ids: [String]) async throws -> Int {
        let idSet = Set(ids)
        return try await store.mutate { all -> Int in
            let before = all.count
            all.removeAll { idSet.contains($0.id) }
            return before - all.count
        }
    }

    /// 删除指定 jobIDs 的全部 result（终态清理级联用），返回删除条数。
    @discardableResult
    func deleteByJobIDs(_ jobIDs: [String]) async throws -> Int {
        let idSet = Set(jobIDs)
        return try await store.mutate { all -> Int in
            let before = all.count
            all.removeAll { idSet.contains($0.jobID) }
            return before - all.count
        }
    }
}
