//
//  HoloMemoryForgettingService.swift
//  Holo
//
//  用户忘记、清空、重新扫描历史与原始数据联动的唯一写入口。
//

import Foundation

protocol HoloMemoryForgettingStore: Sendable {
    func fetch(id: String) async throws -> HoloMemoryRecord?
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord]
    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool
    func loadControlState() async throws -> HoloMemoryControlState
    func saveControlState(_ state: HoloMemoryControlState) async throws
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws
}

#if !HOLO_MEMORY_STANDALONE
extension CoreDataHoloMemoryRepository: HoloMemoryForgettingStore {}
#endif

struct HoloMemoryHistoricalRescanPreview: Equatable, Sendable {
    var learningBaselineAt: Date
    var affectedRecordCount: Int
    var earliestEvidenceAt: Date?
}

enum HoloMemoryForgettingError: Error, Equatable {
    case noLearningBaseline
    case staleRescanPreview
}

struct HoloMemoryForgettingService: Sendable {
    private let store: any HoloMemoryForgettingStore

    init(store: any HoloMemoryForgettingStore) {
        self.store = store
    }

    /// 先写语义墓碑，再擦除正文；即使中途崩溃，也不会被后台重新生成。
    func forget(id: String, now: Date = Date()) async throws -> Bool {
        guard let record = try await store.fetch(id: id) else { return false }
        let control = try await store.loadControlState()
        let version = nextUserDecisionVersion(
            current: control.userDecisionVersion,
            now: now
        )
        let tombstone = HoloMemoryTombstone(
            identityKey: record.id,
            scope: record.scope,
            claimKind: record.claimKind,
            anchorKeys: HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).map(\.stableKey),
            userDecisionVersion: version,
            createdAt: now
        )
        try await store.saveTombstone(tombstone)
        return try await store.markUserDecision(
            id: id,
            decision: .forgotten,
            now: now
        )
    }

    /// learningBaselineAt 先使全部旧证据不可见，再逐条擦除正文，提供崩溃安全的原子可见性。
    func clearAll(now: Date = Date()) async throws -> Int {
        let records = try await store.query(.all)
        var control = try await store.loadControlState()
        control.learningBaselineAt = now
        control.userDecisionVersion = nextUserDecisionVersion(
            current: control.userDecisionVersion,
            now: now
        )
        control.updatedAt = now
        try await store.saveControlState(control)

        var cleared = 0
        for record in records where record.state != .tombstoned && record.state != .deleted {
            if try await store.markUserDecision(
                id: record.id,
                decision: .forgotten,
                now: now
            ) {
                cleared += 1
            }
        }
        return cleared
    }

    func prepareHistoricalRescan() async throws -> HoloMemoryHistoricalRescanPreview {
        let control = try await store.loadControlState()
        guard let baseline = control.learningBaselineAt else {
            throw HoloMemoryForgettingError.noLearningBaseline
        }
        let records = try await store.query(.all)
        let historicalEvidence = records
            .flatMap { $0.evidenceRefs + $0.counterEvidenceRefs }
            .filter { $0.observedAt < baseline }
        return HoloMemoryHistoricalRescanPreview(
            learningBaselineAt: baseline,
            affectedRecordCount: records.count,
            earliestEvidenceAt: historicalEvidence.map(\.observedAt).min()
        )
    }

    func confirmHistoricalRescan(
        preview: HoloMemoryHistoricalRescanPreview,
        now: Date = Date()
    ) async throws {
        var control = try await store.loadControlState()
        guard control.learningBaselineAt == preview.learningBaselineAt else {
            throw HoloMemoryForgettingError.staleRescanPreview
        }
        control.learningBaselineAt = nil
        control.userDecisionVersion = nextUserDecisionVersion(
            current: control.userDecisionVersion,
            now: now
        )
        control.updatedAt = now
        try await store.saveControlState(control)
    }

    /// 原始实体删除时传 nil；修改时传最新 revision，仅让依赖旧 revision 的记忆失效。
    func invalidateMemories(
        dependingOnSourceID sourceID: String,
        currentRevisionDigest: String?,
        now: Date = Date()
    ) async throws -> Int {
        let records = try await store.query(.all)
        var invalidatedIDs = Set(records.compactMap { record -> String? in
            let dependsOnStaleSource = (record.evidenceRefs + record.counterEvidenceRefs).contains {
                $0.sourceID == sourceID &&
                (currentRevisionDigest == nil || $0.revisionDigest != currentRevisionDigest)
            }
            return dependsOnStaleSource ? record.id : nil
        })

        var didExpand = true
        while didExpand {
            didExpand = false
            for record in records where !invalidatedIDs.contains(record.id) {
                if !invalidatedIDs.isDisjoint(with: record.upstreamMemoryIDs) {
                    invalidatedIDs.insert(record.id)
                    didExpand = true
                }
            }
        }

        for var record in records where invalidatedIDs.contains(record.id) {
            let predecessorVersionID = record.versionID
            record.state = .invalidated
            record.recordVersion += 1
            record.predecessorVersionID = predecessorVersionID
            record.updatedAt = now
            try await store.replaceRecordForUserControl(record)
        }
        return invalidatedIDs.count
    }

    private func nextUserDecisionVersion(current: Int64, now: Date) -> Int64 {
        max(current, Int64(now.timeIntervalSince1970 * 1_000)) + 1
    }
}
