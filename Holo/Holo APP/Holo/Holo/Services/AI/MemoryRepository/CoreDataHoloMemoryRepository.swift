//
//  CoreDataHoloMemoryRepository.swift
//  Holo
//
//  以 actor 串行化统一记忆的读取、合并和持久化
//

import CoreData
import Foundation

actor CoreDataHoloMemoryRepository: HoloMemoryRepository {
    enum Storage: Sendable {
        case main
        case sensitive
    }

    private struct StoredRecord: Sendable {
        var record: HoloMemoryRecord
        var storage: Storage
    }

    let controller: HoloMemoryPersistenceController
    private var mutationLocked = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(controller: HoloMemoryPersistenceController) {
        self.controller = controller
    }

    /// 敏感记忆库的后台 context（回收站清空/恢复使用；调用方自行 perform）
    func sensitiveBackgroundContext() -> NSManagedObjectContext {
        controller.sensitiveContainer.newBackgroundContext()
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
            let hasUserControl = existing.record.userDecision != .none
            let existingLineages = Set(existing.record.evidenceRefs.map(\.lineageKey))
            let containsNewEvidence = record.evidenceRefs.contains {
                !existingLineages.contains($0.lineageKey)
            }
            if hasUserControl && !containsNewEvidence {
                return .rejectedByNewerUserControl
            }
            recordToPersist = merge(
                existing: existing.record,
                incoming: record,
                preserveUserControlledFields: hasUserControl
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

    func applyObservationBatch(
        _ records: [HoloMemoryRecord],
        observationKey: String,
        domain: HoloMemoryDomain,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date
    ) async throws -> [HoloMemoryUpsertResult] {
        try await withMutationLock {
            if try await hasSuccessfulObservation(observationKey) {
                return records.map { _ in .duplicateObservation }
            }
            for record in records {
                do { try record.validate() }
                catch { throw HoloMemoryRepositoryError.invalidRecord }
                guard record.scope == .domain, record.primaryDomain == domain else {
                    throw HoloMemoryRepositoryError.invalidRecord
                }
            }

            let control = try await loadControlState()
            var prepared: [(record: HoloMemoryRecord, previousStorage: Storage?)] = []
            var results: [HoloMemoryUpsertResult] = []
            for record in records {
                if try await hasMatchingTombstone(for: record) {
                    results.append(.rejectedByTombstone)
                    continue
                }
                if let baseline = control.learningBaselineAt,
                   record.evidenceRefs.allSatisfy({ $0.observedAt < baseline }) {
                    results.append(.rejectedByNewerUserControl)
                    continue
                }
                let existing = try await fetchStored(id: record.id)
                var recordToPersist = record
                if let existing {
                    // G2（E13）：用户决定保护不再依赖 updatedAt 竞速——双设备同步、
                    // 离线恢复等场景下自动批次的时间戳可能更晚，按时间比会让用户
                    // 决定被自动观察覆盖。只要既有记录带用户决定：无新证据整条拒绝，
                    // 有新证据合并但用户控制字段原样保留。
                    let hasUserControl = existing.record.userDecision != .none
                    let existingLineages = Set(existing.record.evidenceRefs.map(\.lineageKey))
                    let containsNewEvidence = record.evidenceRefs.contains {
                        !existingLineages.contains($0.lineageKey)
                    }
                    if hasUserControl && !containsNewEvidence {
                        results.append(.rejectedByNewerUserControl)
                        continue
                    }
                    recordToPersist = merge(
                        existing: existing.record,
                        incoming: record,
                        preserveUserControlledFields: hasUserControl
                    )
                }
                recordToPersist.lastObservationKey = observationKey
                prepared.append((recordToPersist, existing?.storage))
                results.append(existing == nil ? .inserted : .updated)
            }

            guard let first = prepared.first else {
                try await markObservationSucceeded(
                    observationKey,
                    domain: domain,
                    extractorVersion: extractorVersion,
                    promptVersion: promptVersion,
                    completedAt: completedAt
                )
                return results
            }
            let target: Storage = requiresSensitiveLocalStorage(first.record) ? .sensitive : .main
            guard prepared.allSatisfy({
                (requiresSensitiveLocalStorage($0.record) ? Storage.sensitive : Storage.main) == target
            }) else {
                throw HoloMemoryRepositoryError.persistenceFailed
            }

            let context = container(for: target).newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            let controlGeneration = control.userDecisionVersion
            try await context.perform {
                for item in prepared {
                    try Self.upsertRecord(
                        item.record,
                        observationKey: target == .main ? observationKey : nil,
                        in: context
                    )
                    try HoloKnowledgeIngestion.ingest(
                        record: item.record,
                        controlGeneration: controlGeneration,
                        now: completedAt,
                        in: context
                    )
                }
                do { try context.save() }
                catch {
                    context.rollback()
                    throw HoloMemoryRepositoryError.persistenceFailed
                }
            }
            if target == .sensitive {
                try await markObservationSucceeded(
                    observationKey,
                    domain: domain,
                    extractorVersion: extractorVersion,
                    promptVersion: promptVersion,
                    completedAt: completedAt
                )
            }
            for item in prepared where item.previousStorage != nil && item.previousStorage != target {
                try await deletePersistedRecord(id: item.record.id, from: item.previousStorage!)
            }
            return results
        }
    }

    func fetch(id: String) async throws -> HoloMemoryRecord? {
        try await fetchStored(id: id)?.record
    }

    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] {
        // 分段计时（2026-11-02 性能归因）：全量读+知识门闸的单次耗时此前完全黑箱，
        // 补领 74 秒无法归因。超 400ms 才落日志，正常量级不刷屏。
        let queryClock = ContinuousClock()
        let queryStart = queryClock.now
        let fetchStart = queryClock.now
        let main = try await fetchAll(in: .main)
        let sensitive = try await fetchAll(in: .sensitive)
        let fetchElapsed = queryClock.now - fetchStart
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
        let filtered = byID.values.filter { record in
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

        guard query != .all else { return filtered }
        // 统一决策门闸（v2.2 §4/§6）：所有消费者经由同一 HoloResolvedKnowledge 判定，
        // 不再有 active 旁路。未迁移旧记录走 §7.2 受限只读投影，不通过旧 active 悄悄回退。
        let gateStart = queryClock.now
        let gate = try await knowledgeUsageGate(now: Date())
        let gateElapsed = queryClock.now - gateStart
        let result = filtered.filter { gate.isUsable($0) }
        let totalElapsed = queryClock.now - queryStart
        if totalElapsed > .milliseconds(400) {
            let kind = query == .active ? "active" : (query == .all ? "all" : "domain")
            func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
            NSLog("[HoloMemoryRepository] PERF query(\(kind)) 慢: total=\(ms(totalElapsed))ms fetch=\(ms(fetchElapsed))ms gate=\(ms(gateElapsed))ms records=\(main.count + sensitive.count) usable=\(result.count)")
        }
        return result
    }

    /// 命题知识可用性 → 旧记录别名的门闸投影。
    struct HoloKnowledgeUsageGate: Sendable {
        let usableAliases: Set<String>
        let knownAliases: Set<String>

        func isUsable(_ record: HoloMemoryRecord) -> Bool {
            if knownAliases.contains(record.id) {
                return usableAliases.contains(record.id)
            }
            return HoloKnowledgeLegacyAdapter.isUsableWithoutMigration(record)
        }
    }

    func knowledgeUsageGate(now: Date) async throws -> HoloKnowledgeUsageGate {
        let resolved = try await resolvedKnowledgeAll(now: now)
        var usable: Set<String> = []
        var known: Set<String> = []
        for item in resolved {
            known.formUnion(item.legacyAliases)
            if item.decision.isUsableForAnswering {
                usable.formUnion(item.legacyAliases)
            }
        }
        return HoloKnowledgeUsageGate(usableAliases: usable, knownAliases: known)
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

    /// 存量大扫除（2026-10-29 东林拍板）：把被错误激活的单次流水/单日打卡碎片
    /// 从「已记住」收进历史（archived）。保护边界见 HoloLegacySweepPolicy——
    /// 用户确认/纠正/否决过的与敏感内容一条不碰。幂等：归档后不再命中。
    /// 返回本次归档条数；走正常持久化通道，随 CloudKit 同步到全部设备。
    func archiveLegacyFlowRecords(now: Date) async throws -> Int {
        let candidates = try await query(.all)
        var archived = 0
        for record in candidates where HoloLegacySweepPolicy.shouldSweep(record) {
            try await withMutationLock {
                guard let stored = try await fetchStored(id: record.id) else { return }
                var updated = stored.record
                guard HoloLegacySweepPolicy.shouldSweep(updated) else { return }
                updated.state = .archived
                updated.recordVersion += 1
                updated.predecessorVersionID = stored.record.versionID
                updated.updatedAt = now
                try await persist(updated, in: stored.storage, observationKey: nil)
                archived += 1
            }
        }
        return archived
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
            record.adoptionMetadata = HoloMemoryAdoptionMetadata(
                policyVersion: HoloMemoryActivationPolicy.currentVersion,
                disposition: .userConfirmed,
                reason: .explicitUserConfirmation,
                evaluatedAt: now
            )
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

    func recordUsage(ids: [String], now: Date) async throws {
        guard !ids.isEmpty else { return }
        try await withMutationLock {
            try await recordUsage(ids: ids, now: now, in: .main)
            try await recordUsage(ids: ids, now: now, in: .sensitive)
        }
    }

    /// 使用统计专用写入：只重写 recordData 一列，不动 evidence 行、不碰版本与时间戳，
    /// 把 CloudKit 同步流量压到最低。记录不存在（已删/已归档）直接跳过。
    private func recordUsage(ids: [String], now: Date, in storage: Storage) async throws {
        let context = container(for: storage).newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            let request = NSFetchRequest<HoloMemoryRecordMO>(entityName: "HoloMemoryRecordMO")
            request.predicate = NSPredicate(format: "stableID IN %@", ids)
            let objects = try context.fetch(request)
            guard !objects.isEmpty else { return }
            for object in objects {
                guard var record = try? Self.decoder().decode(HoloMemoryRecord.self, from: object.recordData)
                else { continue }
                record.usageCount = (record.usageCount ?? 0) + 1
                record.lastUsedAt = now
                object.recordData = try Self.encoder().encode(record)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    /// 用户仅删除当前记忆；不写 tombstone，后续新证据仍可形成同类记忆。
    func deleteRecord(id: String) async throws -> Bool {
        try await withMutationLock {
            guard let stored = try await fetchStored(id: id) else { return false }
            try await deletePersistedRecord(id: id, from: stored.storage)
            return true
        }
    }

    /// 标签级 AI 排除（2026-10-21 方案）：删除由指定想法派生的记忆。
    /// 口径「证据含排除想法即删」：thought 域证据命中直接删；跨域融合记录的 evidenceRefs
    /// 可能不含想法 UUID，但上游记忆被删后 upstreamMemoryIDs 悬空，一并删除，
    /// 由观察器从剩余想法重新沉淀。排除语义（隐私）优先于记忆保留。
    /// - Returns: 实际删除条数
    @discardableResult
    func deleteRecordsDerived(fromThoughtIDs thoughtIDs: Set<String>) async throws -> Int {
        guard !thoughtIDs.isEmpty else { return 0 }
        return try await withMutationLock {
            let records = try await query(.all)
            let normalizedKeys = Set(thoughtIDs.map { $0.lowercased() })
            func referencesExcludedThought(_ record: HoloMemoryRecord) -> Bool {
                record.evidenceRefs.contains { ref in
                    guard ref.sourceDomain == .thought else { return false }
                    if let sourceID = ref.sourceID, normalizedKeys.contains(sourceID.lowercased()) { return true }
                    return ref.lineageKey.lowercased().hasPrefix("thought:")
                        && normalizedKeys.contains(String(ref.lineageKey.dropFirst("thought:".count)).lowercased())
                }
            }
            var deletedIDs = Set(records.filter(referencesExcludedThought).map(\.id))
            // 级联：跨域融合记录引用了被删上游
            for record in records where record.scope == .crossDomain && !deletedIDs.contains(record.id) {
                if !Set(record.upstreamMemoryIDs).isDisjoint(with: deletedIDs) {
                    deletedIDs.insert(record.id)
                }
            }
            var deleted = 0
            for id in deletedIDs {
                if let stored = try await fetchStored(id: id) {
                    try await deletePersistedRecord(id: id, from: stored.storage)
                    deleted += 1
                }
            }
            return deleted
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
            request.predicate = NSPredicate(format: "deletedAt == nil")
            let objects = try context.fetch(request)
            // 逐行隔离（方案 v2.2 §7.5 / M06）：单条未知外层枚举或损坏字节不拖垮整批；
            // 原字节保留在库中待诊断，不新建非法枚举、不在消费端 catch 成空列表。
            var decoded: [HoloMemoryRecord] = []
            var quarantined = 0
            for object in objects {
                do {
                    decoded.append(try Self.decoder().decode(HoloMemoryRecord.self, from: object.recordData))
                } catch {
                    quarantined += 1
                }
            }
            if quarantined > 0 {
                NSLog("[HoloMemoryRepository] 隔离无法解码的记忆行: \(quarantined)（原字节保留）")
            }
            return decoded
        }
    }

    private func persist(
        _ record: HoloMemoryRecord,
        in storage: Storage,
        observationKey: String?
    ) async throws {
        let controlGeneration = try await loadControlState().userDecisionVersion
        let context = container(for: storage).newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            try Self.upsertRecord(record, observationKey: observationKey, in: context)
            // 统一写入（v2.2 §6）：旧记录作为来源/候选契约载体，在同一事务内经统一准入
            // 落知识修订；不向旧 recordData 双写新知识，不直接用候选状态授权当前理解。
            try HoloKnowledgeIngestion.ingest(
                record: record,
                controlGeneration: controlGeneration,
                now: record.updatedAt,
                in: context
            )
            do {
                try context.save()
            } catch {
                context.rollback()
                throw HoloMemoryRepositoryError.persistenceFailed
            }
        }
    }

    func hasSuccessfulObservation(_ key: String) async throws -> Bool {
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

    private func markObservationSucceeded(
        _ key: String,
        domain: HoloMemoryDomain,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date
    ) async throws {
        let context = controller.mainContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            try Self.upsertObservation(
                key,
                domain: domain.rawValue,
                extractorVersion: extractorVersion,
                promptVersion: promptVersion,
                completedAt: completedAt,
                in: context
            )
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

    private static func upsertObservation(
        _ key: String,
        domain: String,
        extractorVersion: Int,
        promptVersion: Int,
        completedAt: Date,
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
        object.domain = domain
        object.status = "succeeded"
        object.extractorVersion = Int64(extractorVersion)
        object.promptVersion = Int64(promptVersion)
        object.completedAt = completedAt
    }

    private static func upsertRecord(
        _ record: HoloMemoryRecord,
        observationKey: String?,
        in context: NSManagedObjectContext
    ) throws {
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
        for oldEvidence in try context.fetch(evidenceRequest) { context.delete(oldEvidence) }
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
            try Self.upsertObservation(observationKey, record: record, in: context)
        }
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
            request.predicate = NSPredicate(format: "deletedAt == nil")
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

    func container(for storage: Storage) -> NSPersistentContainer {
        switch storage {
        case .main: return controller.mainContainer
        case .sensitive: return controller.sensitiveContainer
        }
    }

    /// actor 在 await Core Data context 时允许重入，因此写操作还需要显式事务门。
    func withMutationLock<ResultValue>(
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
        merged.lastSupportedAt = [existing.lastSupportedAt, incoming.lastSupportedAt]
            .compactMap { $0 }
            .max()
        merged.recordVersion = max(existing.recordVersion + 1, incoming.recordVersion)
        merged.sensitivity = stricter(existing.sensitivity, incoming.sensitivity)

        if preserveUserControlledFields {
            let predecessor = existing.versionID
            merged.displaySummary = existing.displaySummary
            merged.aiUseSummary = existing.aiUseSummary
            merged.prohibitedInferences = existing.prohibitedInferences
            merged.userDecision = existing.userDecision
            merged.state = existing.state
            merged.adoptionMetadata = existing.adoptionMetadata
            merged.recordVersion = max(existing.recordVersion + 1, incoming.recordVersion)
            merged.predecessorVersionID = predecessor
            merged.updatedAt = max(existing.updatedAt, incoming.updatedAt)
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

    private nonisolated static func requiresSensitiveLocalStorage(_ record: HoloMemoryRecord) -> Bool {
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
