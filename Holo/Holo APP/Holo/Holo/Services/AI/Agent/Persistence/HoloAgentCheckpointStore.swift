//
//  HoloAgentCheckpointStore.swift
//  Holo
//
//  Agent V3.1 — Task 1.3 Agent Checkpoint 仓库（upsert / 按 job 查最新）
//

import Foundation

/// 管理 `HoloAgentCheckpoint` 的持久化；同一 job 可有多个 checkpoint，按 updatedAt 取最新。
actor HoloAgentCheckpointStore {

    private let store: HoloAgentJSONStore<HoloAgentCheckpoint>

    init() {
        self.store = HoloAgentJSONStore(fileName: "agentCheckpoints.json")
    }

    init(directory: URL) {
        self.store = HoloAgentJSONStore(fileName: "agentCheckpoints.json", directory: directory)
    }

    /// 插入或替换（按 id）。
    func upsert(_ checkpoint: HoloAgentCheckpoint) async throws {
        try await store.mutate { all in
            if let index = all.firstIndex(where: { $0.id == checkpoint.id }) {
                all[index] = checkpoint
            } else {
                all.append(checkpoint)
            }
        }
    }

    /// 返回某 job 下 updatedAt 最新的 checkpoint。
    func latestForJob(jobID: String) async -> HoloAgentCheckpoint? {
        let all = await store.load()
        return all
            .filter { $0.jobID == jobID }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// 删除指定 jobIDs 的全部 checkpoint（终态清理级联用），返回删除条数。
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
