//
//  CoreDataHoloMemoryRepository.swift
//  Holo
//
//  以 actor 串行化统一记忆的读取、合并和持久化
//

import CoreData
import Foundation

actor CoreDataHoloMemoryRepository: HoloMemoryRepository {
    private enum Storage: Sendable {
        case main
        case sensitive
    }

    private struct StoredRecord: Sendable {
        var record: HoloMemoryRecord
        var storage: Storage
    }

    private let controller: HoloMemoryPersistenceController
    private var mutationLocked = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(controller: HoloMemoryPersistenceController) {
        self.controller = controller
    }

    func upsert(
        _ record: HoloMemoryRecord,
        observationKey: String?
    ) async throws -> HoloMemoryUpsertResult {
        try await withMutationLock {
            try await upsertUnlocked(record, observationKey: observationKey)
        }
    }

    private func upsertUnlocked(
        _ record: HoloMemoryRecord,
        observationKey: String?
    ) async throws -> HoloMemoryUpsertResult {
        do {
            try record.validate()
        } catch {
            throw HoloMemoryRepositoryError.invalidRecord
        }

        if let observationKey,
           try await hasSuccessfulObservation(observationKey) {
            return .duplicateObservation
        }
        if try await hasMatchingTombstone(for: record) {
            return .rejectedByTombstone
        }

        let control = try await loadControlState()
        if let baseline = control.learningBaselineAt,
           record.evidenceRefs.allSatisfy({ $0.observedAt < baseline }) {
            return .rejectedByNewerUserControl
        }

        let existing = try await fetchStored(id: record.id)
        var recordToPersist = record
        if let existing {
            let userControlIsNewer = existing.record.userDecision != .none &&
                existing.record.updatedAt > record.updatedAt
            let existingLineages = Set(existing.record.evidenceRefs.map(\.lineageKey))
            let containsNewEvidence = record.evidenceRefs.contains {
                !existingLineages.contains($0.lineageKey)
            }
            if userControlIsNewer && !containsNewEvidence {
                return .rejectedByNewerUserControl
            }
            recordToPersist = merge(
                existing: existing.record,
                incoming: record,
                preserveUserControlledFields: userControlIsNewer
            )
        }
        recordToPersist.lastObservationKey = observationKey

        let targetStorage: Storage = requiresSensitiveLocalStorage(recordToPersist)
            ? .sensitive
            : .main
        try await persist(
            recordToPersist,
            in: targetStorage,
            observationKey: targetStorage == .main ? observationKey : nil
        )
        if targetStorage == .sensitive, let observationKey {
            try await markObservationSucceeded(observationKey, record: recordToPersist)
        }

        if let existing, existing.storage != targetStorage {
            try await deletePersistedRecord(id: record.id, from: existing.storage)
        }
        return existing == nil ? .inserted : .updated
    }

    func fetch(id: String) async throws -> HoloMemoryRecord? {
        try await fetchStored(id: id)?.record
    }

    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        let main = try await fetchAll(in: .main)
        let sensitive = try await fetchAll(in: .sensitive)
        var byID: [String: HoloMemoryRecord] = [:]
        for record in main + sensitive {
            if let existing = byID[record.id] {
                byID[record.id] = preferred(existing, record)
            } else {
                byID[record.id] = record
            }
        }

        let unavailable: Set<HoloMemoryState> = [
            .superseded, .invalidated, .archived, .suppressed, .tombstoned, .deleted
        ]
        let control = try await loadControlState()
        return byID.values.filter { record in
            let predatesLearningBaseline: Bool
            if let baseline = control.learningBaselineAt {
                predatesLearningBaseline = !record.evidenceRefs.isEmpty &&
                    record.evidenceRefs.allSatisfy { $0.observedAt < baseline }
            } else {
                predatesLearningBaseline = false
            }
            switch query {
            case .all:
                return true
            case .active:
                return !predatesLearningBaseline && !unavailable.contains(record.state)
            case .domain(let domain):
                return !predatesLearningBaseline &&
                    !unavailable.contains(record.state) &&
                    record.sourceDomains.contains(domain)
            }
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func markUserDecision(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool {
        try await withMutationLock {
            try await markUserDecisionUnlocked(id: id, decision: decision, now: now)
        }
    }

    private func markUserDecisionUnlocked(
        id: String,
        decision: HoloMemoryUserDecision,
        now: Date
    ) async throws -> Bool {
        guard let stored = try await fetchStored(id: id) else { return false }
        var record = stored.record
        record.userDecision = decision
        record.recordVersion += 1
        record.predecessorVersionID = stored.record.versionID
        record.updatedAt = now
        switch decision {
        case .confirmed, .corrected:
            record.state = .active
            record.confidenceScore = max(record.confidenceScore, 0.95)
        case .markedIrrelevant:
            break
        case .rejected:
            record.state = .suppressed
        case .forgotten:
            record.state = .tombstoned
            record.displaySummary = ""
            record.aiUseSummary = ""
            record.evidenceRefs = []
            record.counterEvidenceRefs = []
        case .none:
            break
        }
        try await persist(record, in: stored.storage, observationKey: nil)
        return true
    }

    func supersede(
        id: String,
        replacementVersionID: String,
        now: Date
    ) async throws -> Bool {
        try await withMutationLock {
            try await supersedeUnlocked(
                id: id,
                replacementVersionID: replacementVersionID,
                now: now
            )
        }
    }

    private func supersedeUnlocked(
        id: String,
        replacementVersionID: String,
        now: Date
    ) async throws -> Bool {
        guard let stored = try await fetchStored(id: id) else { return false }
        var record = stored.record
        record.state = .superseded
        record.supersedesMemoryID = replacementVersionID
        record.recordVersion += 1
        record.predecessorVersionID = stored.record.versionID
        record.updatedAt = now
        try await persist(record, in: stored.storage, observationKey: nil)
        return true
    }

    func storageCounts() async throws -> HoloMemoryStorageCounts {
        HoloMemoryStorageCounts(
            mainRecords: try await countRecords(in: .main),
            sensitiveRecords: try await countRecords(in: .sensitive)
        )
    }

    func loadControlState() async throws -> HoloMemoryControlState {
        let context = controller.mainContainer.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlStateMO>(
                entityName: "HoloMemoryControlStateMO"
            )
            request.predicate = NSPredicate(format: "id == %@", HoloMemoryControlState.globalID)
            request.fetchLimit = 1
            guard let object = try context.fetch(request).first else {
                return HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))
            }
            do {
                return try Self.decoder().decode(
                    HoloMemoryControlState.self,
                    from: object.stateData
                )
            } catch {
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    func saveControlState(_ state: HoloMemoryControlState) async throws {
        try await withMutationLock {
            try await saveControlStateUnlocked(state)
        }
    }

    private func saveControlStateUnlocked(_ state: HoloMemoryControlState) async throws {
        let context = controller.mainContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            let request = NSFetchRequest<HoloMemoryControlStateMO>(
                entityName: "HoloMemoryControlStateMO"
            )
            request.predicate = NSPredicate(format: "id == %@", HoloMemoryControlState.globalID)
            request.fetchLimit = 1
            let object = try context.fetch(request).first ??
                NSEntityDescription.insertNewObject(
                    forEntityName: "HoloMemoryControlStateMO",
                    into: context
                ) as! HoloMemoryControlStateMO
            if object.userDecisionVersion > state.userDecisionVersion { return }
            object.id = HoloMemoryControlState.globalID
            object.stateData = try Self.encoder().encode(state)
            object.userDecisionVersion = state.userDecisionVersion
            object.updatedAt = state.updatedAt
            try context.save()
        }
    }

    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {
        try await withMutationLock {
            try await saveTombstoneUnlocked(tombstone)
        }
    }

    private func saveTombstoneUnlocked(_ tombstone: HoloMemoryTombstone) async throws {
        let context = controller.mainContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            let request = NSFetchRequest<HoloMemoryTombstoneMO>(
                entityName: "HoloMemoryTombstoneMO"
            )
            request.predicate = NSPredicate(format: "identityKey == %@", tombstone.identityKey)
            let matches = try context.fetch(request)
            let object = matches.first ??
                NSEntityDescription.insertNewObject(
                    forEntityName: "HoloMemoryTombstoneMO",
                    into: context
                ) as! HoloMemoryTombstoneMO
            if object.userDecisionVersion > tombstone.userDecisionVersion { return }
            for duplicate in matches.dropFirst() { context.delete(duplicate) }
            object.identityKey = tombstone.identityKey
            object.scope = tombstone.scope.rawValue
            object.claimKind = tombstone.claimKind.rawValue
            object.anchorKeysJSON = String(
                data: try Self.encoder().encode(tombstone.anchorKeys.sorted()),
                encoding: .utf8
            ) ?? "[]"
            object.userDecisionVersion = tombstone.userDecisionVersion
            object.createdAt = tombstone.createdAt
            try context.save()
        }
    }

    func fetchTombstone(identityKey: String) async throws -> HoloMemoryTombstone? {
        let context = controller.mainContainer.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryTombstoneMO>(
                entityName: "HoloMemoryTombstoneMO"
            )
            request.predicate = NSPredicate(format: "identityKey == %@", identityKey)
            request.sortDescriptors = [
                NSSortDescriptor(key: "userDecisionVersion", ascending: false)
            ]
            request.fetchLimit = 1
            guard let object = try context.fetch(request).first,
                  let scope = HoloMemoryScope(rawValue: object.scope),
                  let claimKind = HoloMemoryClaimKind(rawValue: object.claimKind) else {
                return nil
            }
            let anchorKeys = (try? Self.decoder().decode(
                [String].self,
                from: Data(object.anchorKeysJSON.utf8)
            )) ?? []
            return HoloMemoryTombstone(
                identityKey: object.identityKey,
                scope: scope,
                claimKind: claimKind,
                anchorKeys: anchorKeys,
                userDecisionVersion: object.userDecisionVersion,
                createdAt: object.createdAt
            )
        }
    }

    func queryTombstones() async throws -> [HoloMemoryTombstone] {
        let context = controller.mainContainer.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryTombstoneMO>(
                entityName: "HoloMemoryTombstoneMO"
            )
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request).compactMap { object in
                guard let scope = HoloMemoryScope(rawValue: object.scope),
                      let claimKind = HoloMemoryClaimKind(rawValue: object.claimKind) else {
                    return nil
                }
                let anchorKeys = (try? Self.decoder().decode(
                    [String].self,
                    from: Data(object.anchorKeysJSON.utf8)
                )) ?? []
                return HoloMemoryTombstone(
                    identityKey: object.identityKey,
                    scope: scope,
                    claimKind: claimKind,
                    anchorKeys: anchorKeys,
                    userDecisionVersion: object.userDecisionVersion,
                    createdAt: object.createdAt
                )
            }
        }
    }

    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws {
        do {
            try record.validate()
        } catch {
            throw HoloMemoryRepositoryError.invalidRecord
        }
        try await withMutationLock {
            let target: Storage = requiresSensitiveLocalStorage(record) ? .sensitive : .main
            try await persist(record, in: target, observationKey: nil)
            try await deletePersistedRecord(
                id: record.id,
                from: target == .main ? .sensitive : .main
            )
        }
    }

    func replaceRecordForMigration(_ record: HoloMemoryRecord) async throws {
        do {
            try record.validate()
        } catch {
            throw HoloMemoryRepositoryError.invalidRecord
        }
        try await withMutationLock {
            let target: Storage = requiresSensitiveLocalStorage(record) ? .sensitive : .main
            try await persist(record, in: target, observationKey: nil)
            try await deletePersistedRecord(
                id: record.id,
                from: target == .main ? .sensitive : .main
            )
        }
    }

    func hardDeleteRecordForMigration(id: String) async throws {
        try await withMutationLock {
            try await deletePersistedRecord(id: id, from: .main)
            try await deletePersistedRecord(id: id, from: .sensitive)
        }
    }

    func deleteTombstoneForMigration(identityKey: String) async throws {
        try await withMutationLock {
            let context = controller.mainContainer.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<HoloMemoryTombstoneMO>(
                    entityName: "HoloMemoryTombstoneMO"
                )
                request.predicate = NSPredicate(format: "identityKey == %@", identityKey)
                for object in try context.fetch(request) { context.delete(object) }
                if context.hasChanges { try context.save() }
            }
        }
    }

    private func fetchStored(id: String) async throws -> StoredRecord? {
        let main = try await fetchRecord(id: id, in: .main)
        let sensitive = try await fetchRecord(id: id, in: .sensitive)
        switch (main, sensitive) {
        case (.none, .none):
            return nil
        case (.some(let record), .none):
            return StoredRecord(record: record, storage: .main)
        case (.none, .some(let record)):
            return StoredRecord(record: record, storage: .sensitive)
        case (.some(let main), .some(let sensitive)):
            let chosen = preferred(main, sensitive)
            return StoredRecord(
                record: chosen,
                storage: chosen == sensitive ? .sensitive : .main
            )
        }
    }

    private func fetchRecord(id: String, in storage: Storage) async throws -> HoloMemoryRecord? {
        let context = container(for: storage).newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "stableID == %@", id)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            request.fetchLimit = 1
            guard let object = try context.fetch(request).first else { return nil }
            do {
                return try Self.decoder().decode(HoloMemoryRecord.self, from: object.recordData)
            } catch {
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    private func fetchAll(in storage: Storage) async throws -> [HoloMemoryRecord] {
        let context = container(for: storage).newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            let objects = try context.fetch(request)
            do {
                return try objects.map {
                    try Self.decoder().decode(HoloMemoryRecord.self, from: $0.recordData)
                }
            } catch {
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    private func persist(
        _ record: HoloMemoryRecord,
        in storage: Storage,
        observationKey: String?
    ) async throws {
        let context = container(for: storage).newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "stableID == %@", record.id)
            let matches = try context.fetch(request)
            let object = matches.first ??
                NSEntityDescription.insertNewObject(
                    forEntityName: "HoloMemoryRecordMO",
                    into: context
                ) as! HoloMemoryRecordMO
            for duplicate in matches.dropFirst() { context.delete(duplicate) }

            object.stableID = record.id
            object.recordVersion = Int64(record.recordVersion)
            object.scope = record.scope.rawValue
            object.state = record.state.rawValue
            object.userDecision = record.userDecision.rawValue
            object.hasHealthLineage = Self.requiresSensitiveLocalStorage(record)
            object.lastObservationKey = record.lastObservationKey
            object.recordData = try Self.encoder().encode(record)
            object.createdAt = record.createdAt
            object.updatedAt = record.updatedAt

            let evidenceRequest = NSFetchRequest<HoloMemoryEvidenceMO>(
                entityName: "HoloMemoryEvidenceMO"
            )
            evidenceRequest.predicate = NSPredicate(format: "recordID == %@", record.id)
            for oldEvidence in try context.fetch(evidenceRequest) {
                context.delete(oldEvidence)
            }
            for evidence in record.evidenceRefs + record.counterEvidenceRefs {
                let evidenceObject = NSEntityDescription.insertNewObject(
                    forEntityName: "HoloMemoryEvidenceMO",
                    into: context
                ) as! HoloMemoryEvidenceMO
                evidenceObject.id = evidence.id
                evidenceObject.recordID = record.id
                evidenceObject.lineageKey = evidence.lineageKey
                evidenceObject.evidenceData = try Self.encoder().encode(evidence)
                evidenceObject.observedAt = evidence.observedAt
            }

            if let observationKey {
                try Self.upsertObservation(
                    observationKey,
                    record: record,
                    in: context
                )
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    private func hasSuccessfulObservation(_ key: String) async throws -> Bool {
        let context = controller.mainContainer.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryObservationRunMO>(
                entityName: "HoloMemoryObservationRunMO"
            )
            request.predicate = NSPredicate(
                format: "observationKey == %@ AND status == %@",
                key,
                "succeeded"
            )
            request.fetchLimit = 1
            return try context.count(for: request) > 0
        }
    }

    private func markObservationSucceeded(
        _ key: String,
        record: HoloMemoryRecord
    ) async throws {
        let context = controller.mainContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            try Self.upsertObservation(key, record: record, in: context)
            try context.save()
        }
    }

    private static func upsertObservation(
        _ key: String,
        record: HoloMemoryRecord,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<HoloMemoryObservationRunMO>(
            entityName: "HoloMemoryObservationRunMO"
        )
        request.predicate = NSPredicate(format: "observationKey == %@", key)
        let matches = try context.fetch(request)
        let object = matches.first ??
            NSEntityDescription.insertNewObject(
                forEntityName: "HoloMemoryObservationRunMO",
                into: context
            ) as! HoloMemoryObservationRunMO
        for duplicate in matches.dropFirst() { context.delete(duplicate) }
        object.observationKey = key
        object.domain = record.primaryDomain?.rawValue ?? "crossDomain"
        object.status = "succeeded"
        object.extractorVersion = Int64(record.extractorVersion)
        object.promptVersion = Int64(record.promptVersion)
        object.completedAt = record.updatedAt
    }

    private func hasMatchingTombstone(for record: HoloMemoryRecord) async throws -> Bool {
        if try await fetchTombstone(identityKey: record.id) != nil { return true }
        return try await queryTombstones().contains {
            HoloSemanticTombstoneMatcher.matches(tombstone: $0, record: record)
        }
    }

    private func countRecords(in storage: Storage) async throws -> Int {
        let context = container(for: storage).newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            return try context.count(for: request)
        }
    }

    private func deletePersistedRecord(id: String, from storage: Storage) async throws {
        let context = container(for: storage).newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "stableID == %@", id)
            for object in try context.fetch(request) { context.delete(object) }
            let evidenceRequest = NSFetchRequest<HoloMemoryEvidenceMO>(entityName: "HoloMemoryEvidenceMO")
            evidenceRequest.predicate = NSPredicate(format: "recordID == %@", id)
            for object in try context.fetch(evidenceRequest) { context.delete(object) }
            if context.hasChanges { try context.save() }
        }
    }

    private func container(for storage: Storage) -> NSPersistentContainer {
        switch storage {
        case .main: return controller.mainContainer
        case .sensitive: return controller.sensitiveContainer
        }
    }

    /// actor 在 await Core Data context 时允许重入，因此写操作还需要显式事务门。
    private func withMutationLock<ResultValue>(
        _ operation: () async throws -> ResultValue
    ) async rethrows -> ResultValue {
        await acquireMutationLock()
        do {
            let result = try await operation()
            releaseMutationLock()
            return result
        } catch {
            releaseMutationLock()
            throw error
        }
    }

    private func acquireMutationLock() async {
        if !mutationLocked {
            mutationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationLock() {
        guard !mutationWaiters.isEmpty else {
            mutationLocked = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private func merge(
        existing: HoloMemoryRecord,
        incoming: HoloMemoryRecord,
        preserveUserControlledFields: Bool
    ) -> HoloMemoryRecord {
        var merged = incoming.updatedAt >= existing.updatedAt ? incoming : existing
        merged.evidenceRefs = mergeEvidence(existing.evidenceRefs, incoming.evidenceRefs)
        merged.counterEvidenceRefs = mergeEvidence(
            existing.counterEvidenceRefs,
            incoming.counterEvidenceRefs
        )
        merged.upstreamMemoryIDs = Array(
            Set(existing.upstreamMemoryIDs + incoming.upstreamMemoryIDs)
        ).sorted()
        merged.createdAt = min(existing.createdAt, incoming.createdAt)
        merged.updatedAt = max(existing.updatedAt, incoming.updatedAt)
        merged.recordVersion = max(existing.recordVersion + 1, incoming.recordVersion)
        merged.sensitivity = stricter(existing.sensitivity, incoming.sensitivity)

        if preserveUserControlledFields {
            merged.displaySummary = existing.displaySummary
            merged.aiUseSummary = existing.aiUseSummary
            merged.prohibitedInferences = existing.prohibitedInferences
            merged.userDecision = existing.userDecision
            merged.state = existing.state
            merged.recordVersion = existing.recordVersion
            merged.predecessorVersionID = existing.predecessorVersionID
            merged.updatedAt = existing.updatedAt
        }
        return merged
    }

    private func mergeEvidence(
        _ lhs: [HoloMemoryEvidenceRef],
        _ rhs: [HoloMemoryEvidenceRef]
    ) -> [HoloMemoryEvidenceRef] {
        var byLineage: [String: HoloMemoryEvidenceRef] = [:]
        for evidence in lhs + rhs {
            if let current = byLineage[evidence.lineageKey],
               current.observedAt > evidence.observedAt {
                continue
            }
            byLineage[evidence.lineageKey] = evidence
        }
        return byLineage.values.sorted {
            if $0.observedAt == $1.observedAt { return $0.id < $1.id }
            return $0.observedAt < $1.observedAt
        }
    }

    private func preferred(
        _ lhs: HoloMemoryRecord,
        _ rhs: HoloMemoryRecord
    ) -> HoloMemoryRecord {
        if lhs.userDecision != .none && rhs.userDecision == .none { return lhs }
        if rhs.userDecision != .none && lhs.userDecision == .none { return rhs }
        if lhs.recordVersion != rhs.recordVersion {
            return lhs.recordVersion > rhs.recordVersion ? lhs : rhs
        }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private func stricter(
        _ lhs: HoloMemorySensitivity,
        _ rhs: HoloMemorySensitivity
    ) -> HoloMemorySensitivity {
        let order: [HoloMemorySensitivity] = [.normal, .highImpact, .sensitive]
        return order[max(order.firstIndex(of: lhs) ?? 0, order.firstIndex(of: rhs) ?? 0)]
    }

    private func requiresSensitiveLocalStorage(_ record: HoloMemoryRecord) -> Bool {
        Self.requiresSensitiveLocalStorage(record)
    }

    private static func requiresSensitiveLocalStorage(_ record: HoloMemoryRecord) -> Bool {
        record.sensitivity == .sensitive ||
        record.primaryDomain == .health ||
        record.sourceDomains.contains(.health) ||
        record.evidenceRefs.contains(where: { $0.sourceDomain == .health }) ||
        record.counterEvidenceRefs.contains(where: { $0.sourceDomain == .health })
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
