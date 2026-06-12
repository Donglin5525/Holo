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
}
