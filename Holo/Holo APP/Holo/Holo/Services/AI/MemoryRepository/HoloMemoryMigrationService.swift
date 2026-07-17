//
//  HoloMemoryMigrationService.swift
//  Holo
//
//  旧长期/情景 JSON → 统一记忆 Repository 的可预览、可回滚迁移
//

import Foundation

struct HoloLegacyMemorySnapshot: Equatable {
    var longTermMemories: [HoloLongTermMemory]
    var episodicMemories: [HoloEpisodicMemory]
    var suppressionRules: [HoloMemorySuppressionRule]
}

struct HoloMemoryMigrationPreview: Codable, Equatable, Sendable {
    var migrationVersion: Int
    var records: [HoloMemoryRecord]
    var tombstones: [HoloMemoryTombstone]
    var legacyIDMap: [String: String]
    var skippedLegacyIDs: [String]
}

enum HoloMemoryMigrationCommitResult: Equatable, Sendable {
    case committed(recordCount: Int, tombstoneCount: Int)
    case alreadyCompleted
}

enum HoloMemoryMigrationError: Error, Equatable {
    case destructiveRerunNotAllowed
    case invalidLegacyRecord(String)
    case verificationFailed
    case missingRollbackJournal
}

protocol HoloMemoryMigrationStateStore: AnyObject, Sendable {
    var completedVersion: Int { get set }
}

final class UserDefaultsHoloMemoryMigrationStateStore: HoloMemoryMigrationStateStore,
    @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "holo_memory_v3_migration_version") {
        self.defaults = defaults
        self.key = key
    }

    var completedVersion: Int {
        get { defaults.integer(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

final class HoloMemoryMigrationService: @unchecked Sendable {
    static let currentVersion = 4

    private struct JournalRecord: Codable {
        var id: String
        var previous: HoloMemoryRecord?
    }

    private struct JournalTombstone: Codable {
        var identityKey: String
        var previous: HoloMemoryTombstone?
    }

    private struct Journal: Codable {
        var migrationVersion: Int
        var records: [JournalRecord]
        var tombstones: [JournalTombstone]
    }

    private let repository: any HoloMemoryRepository
    private let stateStore: any HoloMemoryMigrationStateStore
    private let journalURL: URL
    private let allowDestructiveRerun: Bool
    private let now: () -> Date

    init(
        repository: any HoloMemoryRepository,
        stateStore: any HoloMemoryMigrationStateStore,
        journalURL: URL,
        allowDestructiveRerun: Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.stateStore = stateStore
        self.journalURL = journalURL
        self.allowDestructiveRerun = allowDestructiveRerun
        self.now = now
    }

    func dryRun(
        snapshot: HoloLegacyMemorySnapshot,
        force: Bool = false
    ) throws -> HoloMemoryMigrationPreview {
        if force,
           stateStore.completedVersion >= Self.currentVersion,
           !allowDestructiveRerun {
            throw HoloMemoryMigrationError.destructiveRerunNotAllowed
        }

        var records: [HoloMemoryRecord] = []
        var tombstones: [HoloMemoryTombstone] = []
        var legacyIDMap: [String: String] = [:]
        var skipped: [String] = []

        for memory in snapshot.longTermMemories {
            do {
                let mapped = try map(memory)
                legacyIDMap[memory.id] = mapped.id
                if memory.confirmationState == .rejected {
                    tombstones.append(makeTombstone(from: mapped, createdAt: memory.updatedAt))
                } else {
                    records.append(mapped)
                }
            } catch {
                skipped.append(memory.id)
            }
        }

        for memory in snapshot.episodicMemories {
            do {
                let mapped = try map(memory)
                legacyIDMap[memory.id] = mapped.id
                if memory.state == .rejected {
                    tombstones.append(makeTombstone(from: mapped, createdAt: memory.updatedAt))
                } else {
                    records.append(mapped)
                }
            } catch {
                skipped.append(memory.id)
            }
        }

        for rule in snapshot.suppressionRules where rule.suppressedUntil > now() {
            tombstones.append(try map(rule))
        }

        records = deduplicateRecords(records)
        tombstones = deduplicateTombstones(tombstones)
        return HoloMemoryMigrationPreview(
            migrationVersion: Self.currentVersion,
            records: records,
            tombstones: tombstones,
            legacyIDMap: legacyIDMap,
            skippedLegacyIDs: skipped.sorted()
        )
    }

    func commit(
        _ preview: HoloMemoryMigrationPreview
    ) async throws -> HoloMemoryMigrationCommitResult {
        if stateStore.completedVersion >= preview.migrationVersion {
            return .alreadyCompleted
        }

        let existingCandidates = try await repository.query(.all).filter {
            $0.state == .candidate && $0.userDecision == .none
        }
        let historicalCandidates = existingCandidates.map(activateHistoricalCandidate)
        let recordsToCommit = deduplicateRecords(preview.records + historicalCandidates)

        var recordJournal: [JournalRecord] = []
        for record in recordsToCommit {
            recordJournal.append(JournalRecord(
                id: record.id,
                previous: try await repository.fetch(id: record.id)
            ))
        }
        var tombstoneJournal: [JournalTombstone] = []
        for tombstone in preview.tombstones {
            tombstoneJournal.append(JournalTombstone(
                identityKey: tombstone.identityKey,
                previous: try await repository.fetchTombstone(
                    identityKey: tombstone.identityKey
                )
            ))
        }
        let journal = Journal(
            migrationVersion: preview.migrationVersion,
            records: recordJournal,
            tombstones: tombstoneJournal
        )
        try writeJournal(journal)

        do {
            for record in recordsToCommit {
                let result = try await repository.upsert(record, observationKey: nil)
                guard result != .rejectedByNewerUserControl,
                      result != .rejectedByTombstone else {
                    throw HoloMemoryMigrationError.verificationFailed
                }
            }
            for tombstone in preview.tombstones {
                try await repository.saveTombstone(tombstone)
            }

            for record in recordsToCommit {
                guard try await repository.fetch(id: record.id) != nil else {
                    throw HoloMemoryMigrationError.verificationFailed
                }
            }
            for tombstone in preview.tombstones {
                guard try await repository.fetchTombstone(
                    identityKey: tombstone.identityKey
                ) != nil else {
                    throw HoloMemoryMigrationError.verificationFailed
                }
            }

            stateStore.completedVersion = preview.migrationVersion
            return .committed(
                recordCount: recordsToCommit.count,
                tombstoneCount: preview.tombstones.count
            )
        } catch {
            try? await restore(journal)
            stateStore.completedVersion = 0
            throw error
        }
    }

    func rollback() async throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw HoloMemoryMigrationError.missingRollbackJournal
        }
        let data = try Data(contentsOf: journalURL)
        let journal = try Self.decoder().decode(Journal.self, from: data)
        try await restore(journal)
        stateStore.completedVersion = 0
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func restore(_ journal: Journal) async throws {
        for entry in journal.records {
            try await repository.hardDeleteRecordForMigration(id: entry.id)
            if let previous = entry.previous {
                try await repository.replaceRecordForMigration(previous)
            }
        }
        for entry in journal.tombstones {
            try await repository.deleteTombstoneForMigration(identityKey: entry.identityKey)
            if let previous = entry.previous {
                try await repository.saveTombstone(previous)
            }
        }
    }

    private func map(_ memory: HoloLongTermMemory) throws -> HoloMemoryRecord {
        let resolvedDomain: HoloMemoryDomain = domain(forSubjectKey: memory.subjectKey)
            ?? memory.evidence.compactMap { self.domain(for: $0.source) }.first
            ?? HoloMemoryDomain.profile
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: memory.subjectKey)
        let claimKind: HoloMemoryClaimKind
        let persistenceClass: HoloMemoryPersistenceClass
        switch memory.semanticType {
        case .phaseShift:
            claimKind = .phaseShift
            persistenceClass = .phase
        case .stablePattern:
            claimKind = .recurringPattern
            persistenceClass = .durable
        case .driftSignal:
            claimKind = .hypothesis
            persistenceClass = .currentState
        case .lifeEvent:
            claimKind = .lifeEvent
            persistenceClass = .permanentFact
        case .statMilestone:
            claimKind = .observedFact
            persistenceClass = .durable
        }
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: resolvedDomain,
            sourceDomains: [resolvedDomain],
            claimKind: claimKind,
            anchors: [anchor]
        )
        let evidence: [HoloMemoryEvidenceRef] = memory.evidence.map {
            map($0, fallbackDomain: resolvedDomain)
        }
        guard !evidence.isEmpty else {
            throw HoloMemoryMigrationError.invalidLegacyRecord(memory.id)
        }
        let state: HoloMemoryState
        let decision: HoloMemoryUserDecision
        switch memory.confirmationState {
        case .candidate:
            state = .active
            decision = .none
        case .silentlyAccepted:
            state = .active
            decision = .none
        case .confirmed:
            state = .active
            decision = .confirmed
        case .rejected:
            state = .tombstoned
            decision = .forgotten
        case .archived:
            state = .archived
            decision = .none
        }
        let lastSupportedAt = evidence.map(\.observedAt).max() ?? memory.updatedAt
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: resolvedDomain,
            sourceDomains: [resolvedDomain],
            subjectKey: memory.subjectKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: persistenceClass,
            displaySummary: memory.displaySummary,
            aiUseSummary: memory.aiUseSummary,
            prohibitedInferences: memory.prohibitedInferences,
            evidenceRefs: evidence,
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: memory.createdAt,
            lastSupportedAt: lastSupportedAt,
            expiresAt: memory.expiresAt,
            confidenceScore: score(memory.confidence),
            freshnessScore: HoloMemoryScorer.freshness(
                persistenceClass: persistenceClass,
                lastSupportedAt: lastSupportedAt,
                now: now()
            ),
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now(),
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: memory.sensitivity,
            userDecision: decision,
            adoptionMetadata: memory.confirmationState == .candidate
                ? historicalAdoptionMetadata()
                : nil,
            createdAt: memory.createdAt,
            updatedAt: memory.updatedAt,
            schemaVersion: 1
        )
    }

    private func map(_ memory: HoloEpisodicMemory) throws -> HoloMemoryRecord {
        let resolvedDomain: HoloMemoryDomain = memory.sourceModules
            .compactMap { self.domain(for: $0) }.first
            ?? memory.evidence.compactMap { self.domain(for: $0.source) }.first
            ?? HoloMemoryDomain.profile
        let anchorValue = memory.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anchorValue.isEmpty, !memory.evidence.isEmpty else {
            throw HoloMemoryMigrationError.invalidLegacyRecord(memory.id)
        }
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: anchorValue)
        let claimKind: HoloMemoryClaimKind = memory.hitCount >= 2 ? .hypothesis : .observedFact
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: resolvedDomain,
            sourceDomains: [resolvedDomain],
            claimKind: claimKind,
            anchors: [anchor]
        )
        let evidence: [HoloMemoryEvidenceRef] = memory.evidence.map {
            map($0, fallbackDomain: resolvedDomain)
        }
        let state: HoloMemoryState
        let decision: HoloMemoryUserDecision
        switch memory.state {
        case .observing, .suggested, .promotionCandidate:
            state = .active
            decision = .none
        case .active:
            state = .active
            decision = .none
        case .promoted, .expired, .archived:
            state = .archived
            decision = .none
        case .rejected:
            state = .tombstoned
            decision = .forgotten
        }
        var prohibited = ["迁移自旧情景记忆，需结合最新明细验证"]
        if memory.sourceModules.compactMap({ domain(for: $0) }).count > 1 {
            prohibited.append("旧记录曾包含多个模块，不得据此声明跨域关系")
        }
        let lastSupportedAt = evidence.map(\.observedAt).max() ?? memory.updatedAt
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: resolvedDomain,
            sourceDomains: [resolvedDomain],
            subjectKey: anchorValue,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .currentState,
            displaySummary: memory.userEditedSummary ?? memory.summary,
            aiUseSummary: memory.userEditedSummary ?? memory.summary,
            prohibitedInferences: prohibited,
            evidenceRefs: evidence,
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: memory.createdAt,
            lastSupportedAt: lastSupportedAt,
            expiresAt: memory.expiresAt,
            confidenceScore: score(memory.confidence),
            freshnessScore: HoloMemoryScorer.freshness(
                persistenceClass: .currentState,
                lastSupportedAt: lastSupportedAt,
                now: now()
            ),
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now(),
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: memory.sensitivity,
            userDecision: decision,
            adoptionMetadata: [.observing, .suggested, .promotionCandidate].contains(memory.state)
                ? historicalAdoptionMetadata()
                : nil,
            createdAt: memory.createdAt,
            updatedAt: memory.updatedAt,
            schemaVersion: 1
        )
    }

    private func map(_ rule: HoloMemorySuppressionRule) throws -> HoloMemoryTombstone {
        let keywords = rule.keywordGroups
            .flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        guard !keywords.isEmpty else {
            throw HoloMemoryMigrationError.invalidLegacyRecord(rule.id)
        }
        let canonicalTheme = keywords.joined(separator: "-")
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: canonicalTheme)
        return HoloMemoryTombstone(
            identityKey: "legacy-suppression-\(stableHash(anchor.stableKey))",
            scope: .domain,
            claimKind: .hypothesis,
            anchorKeys: [anchor.stableKey],
            userDecisionVersion: Int64(rule.originalRejectedAt.timeIntervalSince1970),
            createdAt: rule.originalRejectedAt
        )
    }

    private func map(
        _ evidence: HoloLongTermMemoryEvidence,
        fallbackDomain: HoloMemoryDomain
    ) -> HoloMemoryEvidenceRef {
        let sourceDomain = domain(for: evidence.source) ?? fallbackDomain
        let sourceID = evidence.sourceID ?? evidence.id
        return HoloMemoryEvidenceRef(
            id: evidence.id,
            kind: sourceDomain == .health ? .aggregateSnapshot : .entityRef,
            sourceDomain: sourceDomain,
            lineageKey: "legacy|\(evidence.source.rawValue)|\(sourceID)",
            sourceID: evidence.sourceID,
            revisionDigest: stableHash(
                "\(sourceID)|\(evidence.excerpt)|\(evidence.observedAt.timeIntervalSince1970)"
            ),
            observedAt: evidence.observedAt,
            summary: evidence.excerpt
        )
    }

    private func makeTombstone(
        from record: HoloMemoryRecord,
        createdAt: Date
    ) -> HoloMemoryTombstone {
        HoloMemoryTombstone(
            identityKey: record.id,
            scope: record.scope,
            claimKind: record.claimKind,
            anchorKeys: record.anchorRefs.map(\.stableKey).sorted(),
            userDecisionVersion: Int64(createdAt.timeIntervalSince1970),
            createdAt: createdAt
        )
    }

    private func activateHistoricalCandidate(_ record: HoloMemoryRecord) -> HoloMemoryRecord {
        var migrated = record
        migrated.state = .active
        migrated.freshnessScore = HoloMemoryScorer.freshness(
            persistenceClass: record.persistenceClass,
            lastSupportedAt: record.lastSupportedAt ?? record.updatedAt,
            now: now()
        )
        migrated.scoringVersion = HoloMemoryScorer.currentVersion
        migrated.scoreComputedAt = now()
        migrated.recordVersion += 1
        migrated.predecessorVersionID = record.versionID
        migrated.adoptionMetadata = historicalAdoptionMetadata()
        return migrated
    }

    private func historicalAdoptionMetadata() -> HoloMemoryAdoptionMetadata {
        HoloMemoryAdoptionMetadata(
            policyVersion: HoloMemoryActivationPolicy.currentVersion,
            disposition: .historicalMigration,
            reason: .historicalCandidateMigration,
            evaluatedAt: now()
        )
    }

    private func domain(for source: HoloMemorySource) -> HoloMemoryDomain? {
        switch source {
        case .finance: return .finance
        case .tasks: return .task
        case .habits: return .habit
        case .thoughts: return .thought
        case .goals: return .goal
        case .health: return .health
        case .profile: return .profile
        case .conversation: return .conversation
        case .memoryInsight: return nil
        }
    }

    private func domain(forSubjectKey subjectKey: String) -> HoloMemoryDomain? {
        let prefix = subjectKey
            .lowercased()
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init)
        switch prefix {
        case "finance": return .finance
        case "task", "tasks": return .task
        case "habit", "habits": return .habit
        case "thought", "thoughts": return .thought
        case "goal", "goals": return .goal
        case "health": return .health
        case "conversation": return .conversation
        case "profile": return .profile
        default: return nil
        }
    }

    private func score(_ confidence: HoloMemoryConfidence) -> Double {
        switch confidence {
        case .low: return 0.35
        case .medium: return 0.65
        case .high: return 0.9
        }
    }

    private func deduplicateRecords(_ records: [HoloMemoryRecord]) -> [HoloMemoryRecord] {
        var byID: [String: HoloMemoryRecord] = [:]
        for record in records {
            if let existing = byID[record.id] {
                var merged = record.updatedAt >= existing.updatedAt ? record : existing
                let evidence = existing.evidenceRefs + record.evidenceRefs
                merged.evidenceRefs = Dictionary(
                    evidence.map { ($0.lineageKey, $0) },
                    uniquingKeysWith: { first, second in
                        first.observedAt >= second.observedAt ? first : second
                    }
                ).values.sorted { $0.observedAt < $1.observedAt }
                byID[record.id] = merged
            } else {
                byID[record.id] = record
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func deduplicateTombstones(
        _ tombstones: [HoloMemoryTombstone]
    ) -> [HoloMemoryTombstone] {
        var byID: [String: HoloMemoryTombstone] = [:]
        for tombstone in tombstones {
            if let existing = byID[tombstone.identityKey],
               existing.userDecisionVersion > tombstone.userDecisionVersion {
                continue
            }
            byID[tombstone.identityKey] = tombstone
        }
        return byID.values.sorted { $0.identityKey < $1.identityKey }
    }

    private func writeJournal(_ journal: Journal) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
