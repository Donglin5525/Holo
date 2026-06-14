//
//  HoloEvidenceLedger.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.1 本地证据账本
//  所有 Agent 产出的事实证据统一登记在此，支撑可信 claim 校验、去重与孤儿清理。
//  复用 HoloAgentJSONStore 做原子持久化，按 dedupeKey 去重，引用关系合并保序。
//

import Foundation

actor HoloEvidenceLedger: HoloEvidenceLedgerProtocol {

    private let store: HoloAgentJSONStore<HoloEvidenceRecord>

    /// 默认持久化到 Application Support/Holo/Memory/Agent/evidenceLedger.json
    init() {
        self.store = HoloAgentJSONStore(fileName: "evidenceLedger.json")
    }

    /// 指定目录（测试注入）。
    init(directory: URL) {
        self.store = HoloAgentJSONStore(fileName: "evidenceLedger.json", directory: directory)
    }

    func load() async -> [HoloEvidenceRecord] {
        await store.load()
    }

    /// 按 dedupeKey 去重 upsert：同 key 用新记录覆盖，但引用关系（jobIDs / memoryIDs）与旧记录合并去重。
    func upsert(_ records: [HoloEvidenceRecord]) async throws {
        try await store.mutate { all in
            for record in records {
                if let index = all.firstIndex(where: { $0.dedupeKey == record.dedupeKey }) {
                    var merged = record
                    merged.referencedByJobIDs = Self.union(all[index].referencedByJobIDs, record.referencedByJobIDs)
                    merged.referencedByMemoryIDs = Self.union(all[index].referencedByMemoryIDs, record.referencedByMemoryIDs)
                    all[index] = merged
                } else {
                    all.append(record)
                }
            }
        }
    }

    /// 按 id 批量查找，返回存在的记录（顺序不保证）。
    func find(ids: [String]) async -> [HoloEvidenceRecord] {
        let idSet = Set(ids)
        return await store.load().filter { idSet.contains($0.id) }
    }

    /// 标记「无任何引用 + 早于 date」的证据为 orphaned。
    /// 已 archived 的不动（终态）；有引用或未过期的不动。
    func markOrphaned(olderThan date: Date) async throws {
        try await store.mutate { all in
            for index in all.indices {
                let record = all[index]
                let hasReference = !record.referencedByJobIDs.isEmpty || !record.referencedByMemoryIDs.isEmpty
                if !hasReference && record.generatedAt < date && record.status != .archived {
                    all[index].status = .orphaned
                }
            }
        }
    }

    /// 保序合并去重两个 ID 数组。
    private static func union(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in first + second where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}
