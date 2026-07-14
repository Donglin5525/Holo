//
//  HoloMemoryRepository.swift
//  Holo
//
//  统一记忆仓库契约
//

import Foundation

enum HoloMemoryUpsertResult: Equatable, Sendable {
    case inserted
    case updated
    case duplicateObservation
    case rejectedByNewerUserControl
    case rejectedByTombstone
}

enum HoloMemoryRepositoryError: Error, Equatable {
    case invalidRecord
    case encodingFailed
    case persistenceFailed
}

enum HoloMemoryRepositoryQuery: Equatable, Sendable {
    case active
    case all
    case domain(HoloMemoryDomain)
}

struct HoloMemoryStorageCounts: Equatable, Sendable {
    var mainRecords: Int
    var sensitiveRecords: Int
}

struct HoloMemoryControlState: Codable, Equatable, Sendable {
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

protocol HoloMemoryRepository: Sendable {
    func upsert(
        _ record: HoloMemoryRecord,
        observationKey: String?
    ) async throws -> HoloMemoryUpsertResult

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
}
