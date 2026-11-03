//
//  HoloKnowledgeInvalidationService.swift
//  Holo
//
//  知识层来源失效扇出（方案 v2.2 §7.6 / 融合契约 §7「同源变化一起重核」）
//
//  与 DiscoveryInvalidationService 挂同一批信号（业务保存通知 / CloudKit 远端变更 /
//  处理授权变更），分别更新两侧投影；不互相靠通知循环触发新分析。
//  精确路径：变更 sourceRef → 证据快照 sourceRevisions 命中的命题 → 写
//  sourceInvalidation 操作（deleted/revised/excluded），知识重算支持与用途。
//  保守路径（Habit 定义变化/远端变更/授权撤回）：无法定位受影响集合时按 unknown
//  暂停相关用途，待复核器（HoloKnowledgeSourceReconciler）按真实来源状态收敛。
//

import CoreData
import Foundation

@MainActor
final class HoloKnowledgeInvalidationService: NSObject {

    private enum MonitoredEntity {
        static let thought = "Thought"
        static let todoTask = "TodoTask"
        static let habit = "Habit"
        static let habitRecord = "HabitRecord"
        static let checkItem = "CheckItem"
    }

    private let repository: CoreDataHoloMemoryRepository
    private let businessCoordinator: NSPersistentStoreCoordinator?
    private var started = false

    init(
        repository: CoreDataHoloMemoryRepository,
        businessCoordinator: NSPersistentStoreCoordinator? = nil
    ) {
        self.repository = repository
        self.businessCoordinator = businessCoordinator ?? CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSave(_:)),
            name: .NSManagedObjectContextDidSave, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRemoteChange(_:)),
            name: .NSPersistentStoreRemoteChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConsentChange(_:)),
            name: .holoAIDataProcessingConsentDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 事件处理

    @objc private func handleSave(_ note: Notification) {
        guard let context = note.object as? NSManagedObjectContext,
              let coordinator = businessCoordinator,
              context.persistentStoreCoordinator === coordinator
        else { return }

        let extracted: (refs: Set<String>, deletedRefs: Set<String>, conservative: Bool) = context.performAndWait {
            let inserted = (note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
            let updated = (note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
            let deleted = (note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []
            var refs = Set<String>()
            var deletedRefs = Set<String>()
            var conservative = false
            func record(_ id: UUID, key: String) {
                let ref = "\(key):\(id.uuidString)"
                refs.insert(ref)
            }
            for object in inserted.union(updated) {
                switch object.entity.name {
                case MonitoredEntity.thought:
                    if let id = object.value(forKey: "id") as? UUID { record(id, key: "thought") }
                case MonitoredEntity.todoTask:
                    if let id = object.value(forKey: "id") as? UUID { record(id, key: "task") }
                case MonitoredEntity.habitRecord:
                    if let id = object.value(forKey: "id") as? UUID {
                        // 记忆证据用 "habit:<id>"；发现依赖索引用 "habitEvent:<id>"，两个键都发。
                        record(id, key: "habit")
                        record(id, key: "habitEvent")
                    }
                case MonitoredEntity.habit:
                    conservative = true
                case MonitoredEntity.checkItem:
                    if let task = object.value(forKey: "task") as? NSManagedObject,
                       let taskID = task.value(forKey: "id") as? UUID {
                        record(taskID, key: "task")
                    }
                default:
                    continue
                }
            }
            for object in deleted {
                switch object.entity.name {
                case MonitoredEntity.thought:
                    if let id = object.value(forKey: "id") as? UUID {
                        deletedRefs.insert("thought:\(id.uuidString)")
                    }
                case MonitoredEntity.todoTask:
                    if let id = object.value(forKey: "id") as? UUID {
                        deletedRefs.insert("task:\(id.uuidString)")
                    }
                case MonitoredEntity.habitRecord:
                    if let id = object.value(forKey: "id") as? UUID {
                        deletedRefs.insert("habit:\(id.uuidString)")
                        deletedRefs.insert("habitEvent:\(id.uuidString)")
                    }
                case MonitoredEntity.habit:
                    conservative = true
                default:
                    continue
                }
            }
            return (refs, deletedRefs, conservative)
        }

        Task { @MainActor in
            await self.applyInvalidation(
                revisedRefs: extracted.refs.subtracting(extracted.deletedRefs),
                deletedRefs: extracted.deletedRefs,
                conservative: extracted.conservative,
                now: Date()
            )
        }
    }

    @objc private func handleRemoteChange(_ note: Notification) {
        Task { @MainActor in
            await self.applyInvalidation(revisedRefs: [], deletedRefs: [], conservative: true, now: Date())
        }
    }

    @objc private func handleConsentChange(_ note: Notification) {
        Task { @MainActor in
            await self.applyConsentRevocation(now: Date())
        }
    }

    // MARK: - 失效执行

    /// 幂等：操作 ID 由命题+ref+状态+秒级时间桶确定；同桶重复保存不重复落库。
    /// 保守事件（远端变更/仅 Habit 定义变化，无法定位受影响集合）不再给全部命题
    /// 写 unknown（09-R05：全库降级 + 每次同步反复写 unknown）——改为调度增量对账，
    /// 由复核器按真实来源状态收敛；同批带来的可精确定位 refs 仍走精确失效。
    func applyInvalidation(
        revisedRefs: Set<String>,
        deletedRefs: Set<String>,
        conservative: Bool,
        now: Date
    ) async {
        let hasRefs = !revisedRefs.isEmpty || !deletedRefs.isEmpty
        if conservative {
            await reconcileSources()
            guard hasRefs else { return }
        } else {
            guard hasRefs else { return }
        }
        do {
            let snapshot = try await repository.knowledgeStoreSnapshot()
            let bucket = Int(now.timeIntervalSince1970)
            var operations: [HoloKnowledgeOperation] = []

            let changed = revisedRefs.map { ($0, HoloKnowledgeSourceStatus.revised.rawValue) }
                + deletedRefs.map { ($0, HoloKnowledgeSourceStatus.deleted.rawValue) }
            let changedRefs = Set(changed.map(\.0))
            let statusByRef = Dictionary(changed, uniquingKeysWith: { first, _ in first })
            for revision in snapshot.revisions {
                let keys = Set(revision.initialEvidenceSnapshot.sourceRevisions.keys)
                guard !keys.isDisjoint(with: changedRefs) else { continue }
                let hit = changedRefs.intersection(keys).sorted()
                let status = hit.compactMap { statusByRef[$0] }
                    .first { $0 == HoloKnowledgeSourceStatus.deleted.rawValue }
                    ?? HoloKnowledgeSourceStatus.revised.rawValue
                operations.append(HoloKnowledgeOperation(
                    operationID: "srcinv-\(revision.propositionID)-\(HoloKnowledgeIdentity.fnv1a64(hit.joined(separator: ",")))-\(status)-\(bucket)",
                    kind: .sourceInvalidation,
                    propositionID: revision.propositionID,
                    targetSemanticRevisionID: revision.semanticRevisionID,
                    targetSemanticDigest: revision.semanticDigest,
                    controlGeneration: 0,
                    payload: .sourceInvalidation(sourceRefs: hit, status: status),
                    partition: revision.partition,
                    issuedAt: now
                ))
            }
            guard !operations.isEmpty else { return }
            try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: operations)
        } catch {
            NSLog("[HoloKnowledge] 来源失效扇出失败: \(error)")
        }
    }

    /// 增量对账调度（通知不可靠时用读取边界核验收敛；打开页面不触发）。
    private func reconcileSources() async {
        let reconciler = HoloKnowledgeSourceReconciler(
            repository: repository,
            verifier: HoloKnowledgeCoreDataSourceVerifier(
                businessContainer: CoreDataStack.shared.persistentContainer
            )
        )
        do {
            _ = try await reconciler.reconcileInvalidated()
        } catch {
            NSLog("[HoloKnowledge] 保守事件增量对账失败: \(error)")
        }
    }

    /// 全局处理授权撤回：禁止相关新外发；已有知识的来源按权限撤回暂停（恢复授权不自动恢复）。
    private func applyConsentRevocation(now: Date) async {
        do {
            let snapshot = try await repository.knowledgeStoreSnapshot()
            let bucket = Int(now.timeIntervalSince1970)
            let revisionsByProposition = Dictionary(grouping: snapshot.revisions, by: \.propositionID)
            var operations: [HoloKnowledgeOperation] = []
            for (propositionID, revisions) in revisionsByProposition {
                let formation = revisions.last?.semantic.formation ?? .sourceLinked
                guard formation == .sourceLinked || formation == .behavioralInference else { continue }
                operations.append(HoloKnowledgeOperation(
                    operationID: "srcinv-\(propositionID)-all-permissionRevoked-\(bucket)",
                    kind: .sourceInvalidation,
                    propositionID: propositionID,
                    controlGeneration: 0,
                    payload: .sourceInvalidation(sourceRefs: [], status: HoloKnowledgeSourceStatus.permissionRevoked.rawValue),
                    partition: revisions.last?.partition ?? .normal,
                    issuedAt: now
                ))
            }
            guard !operations.isEmpty else { return }
            try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: operations)
        } catch {
            NSLog("[HoloKnowledge] 授权撤回扇出失败: \(error)")
        }
    }
}

// MARK: - 来源复核器（保守 unknown 的收敛）

/// 把保守失效收敛为真实来源状态：verified 回执清除失效，真实失效按最严重落库。
/// 打开页面不扫描全历史——只复核仍处于失效状态的命题（增量、预算受控）。
final class HoloKnowledgeSourceReconciler: Sendable {
    private let repository: CoreDataHoloMemoryRepository
    private let verifier: any HoloKnowledgeSourceVerifying

    init(
        repository: CoreDataHoloMemoryRepository,
        verifier: any HoloKnowledgeSourceVerifying
    ) {
        self.repository = repository
        self.verifier = verifier
    }

    struct Result: Equatable, Sendable {
        var reconciled: Int
        var clearedToVerified: Int
        var confirmedInvalid: Int
    }

    func reconcileInvalidated(now: Date = Date()) async throws -> Result {
        let snapshot = try await repository.knowledgeStoreSnapshot()
        let operationsByProposition = Dictionary(grouping: snapshot.operations, by: \.propositionID)
        var toReconcile: [(propositionID: String, partition: HoloKnowledgePartition, refs: [HoloMemoryEvidenceRef])] = []
        for revision in snapshot.revisions {
            let operations = operationsByProposition[revision.propositionID] ?? []
            guard HoloKnowledgeResolver.persistedSourceStatus(operations: operations).isBlockingUsage else { continue }
            let formation = revision.semantic.formation
            guard formation == .sourceLinked || formation == .behavioralInference else { continue }
            toReconcile.append((revision.propositionID, revision.partition, revision.initialEvidenceSnapshot.supportRefs))
        }
        guard !toReconcile.isEmpty else { return Result(reconciled: 0, clearedToVerified: 0, confirmedInvalid: 0) }

        var operations: [HoloKnowledgeOperation] = []
        var cleared = 0
        var invalid = 0
        let bucket = Int(now.timeIntervalSince1970)
        for item in toReconcile {
            let status = await verifier.verify(all: item.refs)
            let payload: HoloKnowledgeOperationPayload
            if status == .verified {
                cleared += 1
                // 复核回执带全部支持来源 ref：同时清除命题级与 ref 级失效。
                payload = .sourceInvalidation(sourceRefs: item.refs.map(\.lineageKey), status: "verified")
            } else {
                invalid += 1
                payload = .sourceInvalidation(sourceRefs: [], status: status.rawValue)
            }
            operations.append(HoloKnowledgeOperation(
                operationID: "srcreconcile-\(item.propositionID)-\(status.rawValue)-\(bucket)",
                kind: .sourceInvalidation,
                propositionID: item.propositionID,
                controlGeneration: 0,
                payload: payload,
                partition: item.partition,
                issuedAt: now
            ))
        }
        try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: operations)
        return Result(reconciled: toReconcile.count, clearedToVerified: cleared, confirmedInvalid: invalid)
    }
}
