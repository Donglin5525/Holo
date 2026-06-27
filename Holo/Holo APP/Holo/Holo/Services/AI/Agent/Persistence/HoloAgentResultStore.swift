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

    /// 插入或替换（按 id）。
    func upsert(_ result: HoloAgentResult) async throws {
        try await store.mutate { all in
            if let index = all.firstIndex(where: { $0.id == result.id }) {
                all[index] = result
            } else {
                all.append(result)
            }
        }
    }

    /// 返回某 job 的 result（取首个匹配）。
    func forJob(jobID: String) async -> HoloAgentResult? {
        let all = await store.load()
        return all.first { $0.jobID == jobID }
    }

    /// 返回最近一条 result（按 generatedAt 降序），供记忆长廊展示。
    func latest() async -> HoloAgentResult? {
        let all = await store.load()
        return all.max(by: { $0.generatedAt < $1.generatedAt })
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
