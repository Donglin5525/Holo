//
//  HoloMemoryCompactionService.swift
//  Holo
//
//  统一记忆容量治理：只归档可重建的自动记忆，不删除用户确认事实和墓碑。
//

import Foundation

nonisolated enum HoloMemoryCapacityPolicy {
    static let maximumActiveRecordsPerDomain = 50
    static let maximumActiveCrossDomainRecords = 100
    static let maximumHistoricalRecordBytes = 8 * 1_024 * 1_024
    static let maximumEvidenceMetadataBytes = 4 * 1_024 * 1_024
}

nonisolated struct HoloMemoryEncodedFootprint: Equatable, Sendable {
    var historicalRecordBytes: Int
    var evidenceMetadataBytes: Int
    var exceedsHistoricalRecordLimit: Bool
    var exceedsEvidenceMetadataLimit: Bool
}

nonisolated struct HoloMemoryCompactionPlan: Equatable, Sendable {
    var archiveRecordIDs: [String]
    var retainedRecordIDs: [String]
    var preservedTombstoneIDs: [String]
    var protectedOverflowByScope: [String: Int]
    var encodedFootprint: HoloMemoryEncodedFootprint
}

struct HoloMemoryCompactionService: Sendable {
    func plan(
        records: [HoloMemoryRecord],
        tombstones: [HoloMemoryTombstone]
    ) -> HoloMemoryCompactionPlan {
        var archiveIDs = Set<String>()
        var retainedIDs = Set(records.map(\.id))
        var overflow: [String: Int] = [:]

        for domain in HoloMemoryDomain.allCases {
            let scoped = records.filter {
                $0.scope == .domain &&
                $0.primaryDomain == domain &&
                $0.state == .active &&
                [.currentState, .phase, .durable].contains($0.persistenceClass)
            }
            let result = compactableOverflow(
                scoped,
                limit: HoloMemoryCapacityPolicy.maximumActiveRecordsPerDomain
            )
            archiveIDs.formUnion(result.archiveIDs)
            if result.protectedOverflow > 0 {
                overflow["domain:\(domain.rawValue)"] = result.protectedOverflow
            }
        }

        let crossDomain = records.filter {
            $0.scope == .crossDomain && $0.state == .active
        }
        let crossResult = compactableOverflow(
            crossDomain,
            limit: HoloMemoryCapacityPolicy.maximumActiveCrossDomainRecords
        )
        archiveIDs.formUnion(crossResult.archiveIDs)
        if crossResult.protectedOverflow > 0 {
            overflow["cross-domain"] = crossResult.protectedOverflow
        }

        retainedIDs.subtract(archiveIDs)
        return HoloMemoryCompactionPlan(
            archiveRecordIDs: archiveIDs.sorted(),
            retainedRecordIDs: retainedIDs.sorted(),
            preservedTombstoneIDs: tombstones.map(\.identityKey).sorted(),
            protectedOverflowByScope: overflow,
            encodedFootprint: Self.measureEncodedFootprint(records: records)
        )
    }

    #if !HOLO_MEMORY_STANDALONE
    func compact(
        repository: any HoloMemoryRepository,
        now: Date = Date()
    ) async throws -> HoloMemoryCompactionPlan {
        let records = try await repository.query(.all)
        let tombstones = try await repository.queryTombstones()
        let result = plan(records: records, tombstones: tombstones)
        for id in result.archiveRecordIDs {
            guard var record = try await repository.fetch(id: id),
                  !Self.isProtected(record) else { continue }
            let predecessor = record.versionID
            record.state = .archived
            record.recordVersion += 1
            record.predecessorVersionID = predecessor
            record.updatedAt = now
            try await repository.replaceRecordForUserControl(record)
        }
        return result
    }
    #endif

    static func measureEncodedFootprint(
        records: [HoloMemoryRecord]
    ) -> HoloMemoryEncodedFootprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordBytes = (try? encoder.encode(records).count) ?? Int.max
        let evidence = records.flatMap { $0.evidenceRefs + $0.counterEvidenceRefs }
        let evidenceBytes = (try? encoder.encode(evidence).count) ?? Int.max
        return HoloMemoryEncodedFootprint(
            historicalRecordBytes: recordBytes,
            evidenceMetadataBytes: evidenceBytes,
            exceedsHistoricalRecordLimit: recordBytes > HoloMemoryCapacityPolicy.maximumHistoricalRecordBytes,
            exceedsEvidenceMetadataLimit: evidenceBytes > HoloMemoryCapacityPolicy.maximumEvidenceMetadataBytes
        )
    }

    private func compactableOverflow(
        _ records: [HoloMemoryRecord],
        limit: Int
    ) -> (archiveIDs: [String], protectedOverflow: Int) {
        guard records.count > limit else { return ([], 0) }
        let protected = records.filter(Self.isProtected)
        let compactable = records.filter { !Self.isProtected($0) }.sorted(by: Self.preferred)
        let availableSlots = max(0, limit - protected.count)
        let archive = compactable.dropFirst(availableSlots).map(\.id)
        return (archive, max(0, protected.count - limit))
    }

    private static func isProtected(_ record: HoloMemoryRecord) -> Bool {
        record.persistenceClass == .permanentFact ||
        [.confirmed, .corrected].contains(record.userDecision)
    }

    private static func preferred(_ lhs: HoloMemoryRecord, _ rhs: HoloMemoryRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.confidenceScore != rhs.confidenceScore {
            return lhs.confidenceScore > rhs.confidenceScore
        }
        return lhs.id < rhs.id
    }
}
