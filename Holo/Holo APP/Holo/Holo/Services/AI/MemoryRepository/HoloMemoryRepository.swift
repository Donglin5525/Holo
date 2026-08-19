//
//  HoloMemoryRepository.swift
//  Holo
//
//  统一记忆仓库契约
//

import Foundation

nonisolated enum HoloMemoryUpsertResult: Equatable, Sendable {
    case inserted
    case updated
    case duplicateObservation
    case rejectedByNewerUserControl
    case rejectedByTombstone
}

nonisolated enum HoloMemoryRepositoryError: Error, Equatable {
    case invalidRecord
    case encodingFailed
    case persistenceFailed
}

nonisolated enum HoloMemoryRepositoryQuery: Equatable, Sendable {
    case active
    case all
    case domain(HoloMemoryDomain)
}

nonisolated struct HoloMemoryStorageCounts: Equatable, Sendable {
    var mainRecords: Int
    var sensitiveRecords: Int
}

nonisolated struct HoloMemoryControlState: Codable, Equatable, Sendable {
    static let globalID = "global"

    var automaticMemoryEnabled: Bool
    var memoryAssistedAnsweringEnabled: Bool
    var learningBaselineAt: Date?
    var userDecisionVersion: Int64
    var updatedAt: Date

    static func initial(now: Date = Date()) -> HoloMemoryControlState {
        HoloMemoryControlState(
            automaticMemoryEnabled: false,
            memoryAssistedAnsweringEnabled: false,
            learningBaselineAt: nil,
            userDecisionVersion: 0,
            updatedAt: now
        )
    }
}

nonisolated struct HoloMemoryTombstone: Codable, Equatable, Identifiable, Sendable {
    var id: String { identityKey }
    var identityKey: String
    var scope: HoloMemoryScope
    var claimKind: HoloMemoryClaimKind
    var anchorKeys: [String]
    var userDecisionVersion: Int64
    var createdAt: Date
}

protocol HoloMemoryRepository: Sendable {
    func upsert(
        _ record: HoloMemoryRecord,
        observationKey: String?
    ) async throws -> HoloMemoryUpsertResult
    func hasSuccessfulObservation(_ key: String) async throws -> Bool
    func applyObservationBatch(
        _ records: [HoloMemoryRecord],
        observationKey: String,
        domain: HoloMemoryDomain,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date
    ) async throws -> [HoloMemoryUpsertResult]

    func fetch(id: String) async throws -> HoloMemoryRecord?
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord]
    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool
    func supersede(
        id: String,
        replacementVersionID: String,
        now: Date
    ) async throws -> Bool
    func storageCounts() async throws -> HoloMemoryStorageCounts
    func loadControlState() async throws -> HoloMemoryControlState
    func saveControlState(_ state: HoloMemoryControlState) async throws
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws
    func fetchTombstone(identityKey: String) async throws -> HoloMemoryTombstone?
    func queryTombstones() async throws -> [HoloMemoryTombstone]
    /// 用户忘记、清空或原始数据失效时使用；绕过自动合并，但仍执行 Schema 校验。
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws

    /// 记录「记忆参与 AI 回答」的使用统计。专用通道：只改 usageCount/lastUsedAt，
    /// 不 bump recordVersion、不改 updatedAt、不写 observationKey、不触发萃取调度——
    /// 避免污染版本链与 userControlIsNewer 合并判定。
    func recordUsage(ids: [String], now: Date) async throws

    /// 仅供版本化迁移的 journal 回滚使用，不得暴露给普通业务调用方。
    func replaceRecordForMigration(_ record: HoloMemoryRecord) async throws
    func hardDeleteRecordForMigration(id: String) async throws
    func deleteTombstoneForMigration(identityKey: String) async throws
}
