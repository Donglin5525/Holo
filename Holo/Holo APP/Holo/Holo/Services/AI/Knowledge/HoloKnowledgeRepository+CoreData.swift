//
//  HoloKnowledgeRepository+CoreData.swift
//  Holo
//
//  通用知识在统一记忆仓库内的持久化（方案 v2.2 §7.1）
//
//  两个 vNext 实体同属现有普通/敏感分区，由本仓库（同一 actor）访问：
//  - 与旧记录写入共享同一 NSManagedObjectContext 保存 → 同分区一个 Core Data 事务；
//  - CloudKit 无唯一约束：重试复用同 ID；同步重复行在读取侧按逻辑 ID 确定性归并；
//  - 新控制不写旧 HoloMemoryControlEventMO（旧重放器遇新实体会误标完成）。
//

import CoreData
import Foundation

// MARK: - 读结果（确定性归并后）

nonisolated struct HoloKnowledgeStoreSnapshot: Sendable {
    var revisions: [HoloKnowledgeRevision]
    var operations: [HoloKnowledgeOperation]
    /// 同逻辑 ID 不同不可变内容（CloudKit 并发写入/设备时钟）：保留双份并标记；
    /// 解析器对受影响命题保守限制，不以 fetch 顺序决胜（09-R07）。
    var conflictingRevisionIDs: Set<String> = []
    var conflictingOperationIDs: Set<String> = []
    /// 受冲突行影响的命题集合：快照构建期一次性归并（2026-11-02）。
    /// resolvedKnowledgeAll 的全命题循环此前逐命题全量扫修订/操作表判定冲突
    /// （O(P×R)，数千命题×数千修订=百万次比较），是 query(.active) 的大头之一。
    var conflictedPropositionIDs: Set<String> = []
    /// 原字节在库但解码失败的行所属命题（受影响命题限制使用，原始字节保留待诊断，09-R06）。
    var unreadablePropositionIDs: Set<String> = []

    var unreadableSummary: String {
        let count = unreadablePropositionIDs.count
        return count > 0 ? "unreadable:\(count)" : ""
    }

    /// 该命题存在不可读数据或同 ID 内容冲突 → 解析器保守限制（09-R06/R07）。
    func isUnreadableOrConflicted(propositionID: String) -> Bool {
        if unreadablePropositionIDs.contains(propositionID) { return true }
        if revisions.contains(where: { $0.propositionID == propositionID && conflictingRevisionIDs.contains($0.semanticRevisionID) }) { return true }
        if operations.contains(where: { $0.propositionID == propositionID && conflictingOperationIDs.contains($0.operationID) }) { return true }
        return false
    }

    /// 预计算版判定（全命题循环专用）：与 isUnreadableOrConflicted 同语义，
    /// 但用构建期归并好的命题集合做 O(1) 查找，替代逐命题全表扫。
    func isRestrictedByDataIssues(propositionID: String) -> Bool {
        unreadablePropositionIDs.contains(propositionID)
            || conflictedPropositionIDs.contains(propositionID)
    }

    /// 把刚重读的本机记录作为待确认稿纳入同一投影。预览不落库，反馈时与操作一起写入。
    func includingProposal(
        _ proposal: HoloKnowledgeRevision, controlGeneration: Int64, now: Date
    ) -> Self {
        var snapshot = self
        if !revisions.contains(where: { $0.id == proposal.id }) {
            var revision = proposal
            revision.createdAt = now
            snapshot.revisions.append(revision)
        }
        let evidence = proposal.initialEvidenceSnapshot
        let operationID = "proposal-evidence-\(proposal.id)-\(evidence.id)"
        if !operations.contains(where: { $0.operationID == operationID }) {
            snapshot.operations.append(HoloKnowledgeOperation(
                operationID: operationID, kind: .evidenceSnapshot,
                propositionID: proposal.propositionID, targetSemanticRevisionID: proposal.id,
                targetSemanticDigest: proposal.semanticDigest, controlGeneration: controlGeneration,
                payload: .evidenceSnapshot(evidence), partition: proposal.partition, issuedAt: now
            ))
        }
        return snapshot
    }

    func resolve(
        propositionID: String, controlGeneration: Int64, learningBaselineAt: Date?, now: Date
    ) -> HoloResolvedKnowledge? {
        HoloKnowledgeResolver.resolve(.init(
            propositionID: propositionID, revisions: revisions, operations: operations,
            sourceStatus: HoloKnowledgeResolver.persistedSourceStatus(operations: operations),
            controlGeneration: controlGeneration, learningBaselineAt: learningBaselineAt,
            hasUnreadableData: isUnreadableOrConflicted(propositionID: propositionID), now: now
        ))
    }
}

// MARK: - 仓库扩展

extension CoreDataHoloMemoryRepository {

    // MARK: 同上下文写入（供旧记录写路径在同一事务内联知识落库）

    /// 幂等：同 semanticRevisionID 已存在时不重复插入（返回 false 表示已存在）。
    /// 同步出现相同逻辑 ID 的重复行在读取侧归并；写入侧按「先到先得」。
    static func upsertKnowledgeRevision(
        _ revision: HoloKnowledgeRevision,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = NSFetchRequest<HoloMemoryKnowledgeRevisionMO>(
            entityName: "HoloMemoryKnowledgeRevisionMO"
        )
        request.predicate = NSPredicate(format: "semanticRevisionID == %@", revision.semanticRevisionID)
        let matches = try context.fetch(request)
        guard matches.isEmpty else { return false }
        let object = NSEntityDescription.insertNewObject(
            forEntityName: "HoloMemoryKnowledgeRevisionMO",
            into: context
        ) as! HoloMemoryKnowledgeRevisionMO
        object.propositionID = revision.propositionID
        object.semanticRevisionID = revision.semanticRevisionID
        object.semanticDigest = revision.semanticDigest
        object.topicID = revision.topicID
        object.partition = revision.partition.rawValue
        object.revisionData = try knowledgeEncoder().encode(revision)
        object.createdAt = revision.createdAt
        object.schemaVersion = Int64(revision.schemaVersion)
        return true
    }

    /// 幂等：同 operationID 已存在 = 重试成功（返回 false）。
    static func upsertKnowledgeOperation(
        _ operation: HoloKnowledgeOperation,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
            entityName: "HoloMemoryKnowledgeOperationMO"
        )
        request.predicate = NSPredicate(format: "operationID == %@", operation.operationID)
        let matches = try context.fetch(request)
        guard matches.isEmpty else { return false }
        let object = NSEntityDescription.insertNewObject(
            forEntityName: "HoloMemoryKnowledgeOperationMO",
            into: context
        ) as! HoloMemoryKnowledgeOperationMO
        object.operationID = operation.operationID
        object.propositionID = operation.propositionID
        object.kind = operation.kind.rawValue
        object.targetSemanticRevisionID = operation.targetSemanticRevisionID
        object.priorOperationIDsJSON = String(
            data: try knowledgeEncoder().encode(operation.priorOperationIDs.sorted()),
            encoding: .utf8
        ) ?? "[]"
        object.controlGeneration = operation.controlGeneration
        object.partition = operation.partition.rawValue
        object.operationData = try knowledgeEncoder().encode(operation)
        object.issuedAt = operation.issuedAt
        object.appliedAt = operation.issuedAt
        object.schemaVersion = Int64(operation.schemaVersion)
        return true
    }

    // MARK: 独立写入（用户控制 / 证据刷新 / 提示记录 / 迁移）

    /// 同分区一个事务：必要新修订 + 操作 + 收据一次保存（§2.4 用户纠正事务）。
    /// 跨分区没有原子事务：每个分区各自一个事务；修订只写自己所属的分区
    /// （09-R09：禁止把一份 revision 无条件插进两个库）。
    func saveKnowledgeRevisionAndOperation(
        revision: HoloKnowledgeRevision?,
        operations: [HoloKnowledgeOperation]
    ) async throws {
        try await withMutationLock {
            let partitions: Set<HoloKnowledgePartition> = Set(
                (revision.map { [$0.partition] } ?? []) + operations.map(\.partition)
            )
            for partition in partitions {
                let context = knowledgeContainer(for: partition).newBackgroundContext()
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                try await context.perform {
                    if let revision, revision.partition == partition {
                        _ = try Self.upsertKnowledgeRevision(revision, in: context)
                    }
                    for operation in operations where operation.partition == partition {
                        _ = try Self.upsertKnowledgeOperation(operation, in: context)
                    }
                    do { try context.save() }
                    catch {
                        context.rollback()
                        throw HoloMemoryRepositoryError.persistenceFailed
                    }
                }
            }
        }
    }

    // MARK: 读取（双分区 + 确定性归并）

    /// 迁移复评反查：旧记录在**指定策略版本集合**下导入过的命题
    /// （aliasImport 操作 → [legacyRecordID: Set<propositionID>]）。
    /// 引擎升版复评时用它找到「上一版当有价值导入、本版判应退出」的旧命题。
    func knowledgeImportedPropositions(
        legacyRecordIDs: [String],
        policyVersions: [Int]
    ) async throws -> [String: Set<String>] {
        guard !legacyRecordIDs.isEmpty, !policyVersions.isEmpty else { return [:] }
        let suffixes = Set(policyVersions.map { "-p\($0)" })
        let idSet = Set(legacyRecordIDs)
        var result: [String: Set<String>] = [:]
        for storage in [Storage.main, .sensitive] {
            let context = container(for: storage).newBackgroundContext()
            let found = try await context.perform { () -> [HoloKnowledgeOperation] in
                let request = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
                    entityName: "HoloMemoryKnowledgeOperationMO"
                )
                request.predicate = NSPredicate(format: "kind == %@", HoloKnowledgeOperationKind.aliasImport.rawValue)
                return try context.fetch(request).compactMap {
                    try? Self.knowledgeDecoder().decode(HoloKnowledgeOperation.self, from: $0.operationData)
                }
            }
            for op in found {
                guard op.kind == .aliasImport,
                      case .aliasImport(let legacyRecordID, _) = op.payload,
                      idSet.contains(legacyRecordID),
                      suffixes.contains(where: { op.operationID.hasSuffix($0) }) else { continue }
                result[legacyRecordID, default: []].insert(op.propositionID)
            }
        }
        return result
    }

    func knowledgeStoreSnapshot() async throws -> HoloKnowledgeStoreSnapshot {
        try await knowledgeStoreSnapshot(propositionID: nil)
    }

    func knowledgeStoreSnapshot(propositionID: String?) async throws -> HoloKnowledgeStoreSnapshot {
        var revisions: [HoloKnowledgeRevision] = []
        var operations: [HoloKnowledgeOperation] = []
        var conflictingRevisionIDs: Set<String> = []
        var conflictingOperationIDs: Set<String> = []
        var unreadablePropositionIDs: Set<String> = []
        for storage in [Storage.main, .sensitive] {
            let context = container(for: storage).newBackgroundContext()
            let decoded = try await context.perform { () -> (revisions: [HoloKnowledgeRevision], operations: [HoloKnowledgeOperation], quarantinedPropositions: Set<String>) in
                var revisions: [HoloKnowledgeRevision] = []
                var operations: [HoloKnowledgeOperation] = []
                var quarantinedPropositions: Set<String> = []

                let revisionRequest = NSFetchRequest<HoloMemoryKnowledgeRevisionMO>(
                    entityName: "HoloMemoryKnowledgeRevisionMO"
                )
                revisionRequest.predicate = NSPredicate(format: "deletedAt == nil")
                if let propositionID {
                    revisionRequest.predicate = NSPredicate(
                        format: "deletedAt == nil AND propositionID == %@", propositionID
                    )
                }
                for object in try context.fetch(revisionRequest) {
                    do {
                        revisions.append(try Self.knowledgeDecoder().decode(HoloKnowledgeRevision.self, from: object.revisionData))
                    } catch {
                        // 逐行隔离（§7.5）：未知/损坏行不拖垮整批，原字节保留在库中待诊断；
                        // MO 的 propositionID 列可定位受影响命题 → 限制使用（09-R06）。
                        if !object.propositionID.isEmpty {
                            quarantinedPropositions.insert(object.propositionID)
                        }
                    }
                }

                let operationRequest = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
                    entityName: "HoloMemoryKnowledgeOperationMO"
                )
                if let propositionID {
                    operationRequest.predicate = NSPredicate(format: "propositionID == %@", propositionID)
                }
                for object in try context.fetch(operationRequest) {
                    do {
                        operations.append(try Self.knowledgeDecoder().decode(HoloKnowledgeOperation.self, from: object.operationData))
                    } catch {
                        if !object.propositionID.isEmpty {
                            quarantinedPropositions.insert(object.propositionID)
                        }
                    }
                }
                return (revisions, operations, quarantinedPropositions)
            }
            revisions.append(contentsOf: decoded.revisions)
            operations.append(contentsOf: decoded.operations)
            unreadablePropositionIDs.formUnion(decoded.quarantinedPropositions)
            if !decoded.quarantinedPropositions.isEmpty {
                NSLog("[HoloKnowledge] 隔离无法解码的知识行，受影响命题: \(decoded.quarantinedPropositions.sorted())")
            }
        }

        // CloudKit 同步重复行归并（09-R07）：相同逻辑 ID 且不可变内容一致 → 归并为一条；
        // 相同 ID 不同内容 → 保留双份并标记冲突（解析器对受影响命题保守限制，
        // 不以 fetch 顺序取胜）。比较用规范化重编码，不直接比原始字节
        // （同内容不同键序/设备编码差异不应误报冲突）。
        // 快路径：单元素组无重复可比，跳过规范化重编码（大量命题只出现一次，
        // 全库重编码是管理页打开的主要成本之一）。
        var revisionsByID: [String: [HoloKnowledgeRevision]] = [:]
        for revision in revisions {
            revisionsByID[revision.semanticRevisionID, default: []].append(revision)
        }
        var mergedRevisions: [HoloKnowledgeRevision] = []
        var conflictedPropositions: Set<String> = []
        for (id, group) in revisionsByID {
            if group.count == 1 {
                mergedRevisions.append(group[0])
            } else if Set(group.map(\.canonicalContentDigest)).count <= 1 {
                mergedRevisions.append(group[0])
            } else {
                mergedRevisions.append(contentsOf: group)
                conflictingRevisionIDs.insert(id)
                conflictedPropositions.insert(group[0].propositionID)
            }
        }
        var operationsByID: [String: [HoloKnowledgeOperation]] = [:]
        for operation in operations {
            operationsByID[operation.operationID, default: []].append(operation)
        }
        var mergedOperations: [HoloKnowledgeOperation] = []
        for (id, group) in operationsByID {
            if group.count == 1 {
                mergedOperations.append(group[0])
            } else if Set(group.map(\.canonicalContentDigest)).count <= 1 {
                mergedOperations.append(group[0])
            } else {
                mergedOperations.append(contentsOf: group)
                conflictingOperationIDs.insert(id)
                conflictedPropositions.insert(group[0].propositionID)
            }
        }
        if !conflictingRevisionIDs.isEmpty || !conflictingOperationIDs.isEmpty {
            NSLog("[HoloKnowledge] 检测到相同ID不同内容的冲突行，受影响项保守限制: revisions=\(conflictingRevisionIDs.sorted()) operations=\(conflictingOperationIDs.sorted())")
        }
        return HoloKnowledgeStoreSnapshot(
            revisions: mergedRevisions.sorted { $0.createdAt < $1.createdAt },
            operations: mergedOperations.sorted { $0.issuedAt < $1.issuedAt },
            conflictingRevisionIDs: conflictingRevisionIDs,
            conflictingOperationIDs: conflictingOperationIDs,
            conflictedPropositionIDs: conflictedPropositions,
            unreadablePropositionIDs: unreadablePropositionIDs
        )
    }

    func knowledgeOperation(operationID: String) async throws -> HoloKnowledgeOperation? {
        for storage in [Storage.main, .sensitive] {
            let context = container(for: storage).newBackgroundContext()
            if let found = try await context.perform({ () -> HoloKnowledgeOperation? in
                let request = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
                    entityName: "HoloMemoryKnowledgeOperationMO"
                )
                request.predicate = NSPredicate(format: "operationID == %@", operationID)
                request.fetchLimit = 1
                guard let object = try context.fetch(request).first else { return nil }
                return try Self.knowledgeDecoder().decode(HoloKnowledgeOperation.self, from: object.operationData)
            }) {
                return found
            }
        }
        return nil
    }

    /// 迁移收据目录（policyVersion 对应批次）：重复执行不重复确认或新增知识。
    func knowledgeMigrationReceipts(
        policyVersion: Int
    ) async throws -> [String: HoloKnowledgeMigrationReceipt] {
        let snapshot = try await knowledgeStoreSnapshot()
        var receipts: [String: HoloKnowledgeMigrationReceipt] = [:]
        for operation in snapshot.operations {
            guard case .migrationReceipt(let receipt) = operation.payload,
                  receipt.policyVersion == policyVersion else { continue }
            if receipts[receipt.processingKey] == nil {
                receipts[receipt.processingKey] = receipt
            }
        }
        return receipts
    }

    // MARK: 高层读取：统一决策投影

    /// 一个命题的权威投影（来源状态由持久化的失效操作推导；管理页另做实时核验）。
    func resolvedKnowledge(propositionID: String, now: Date) async throws -> HoloResolvedKnowledge? {
        let snapshot = try await knowledgeStoreSnapshot(propositionID: propositionID)
        let control = try await loadControlState()
        return snapshot.resolve(
            propositionID: propositionID, controlGeneration: control.userDecisionVersion,
            learningBaselineAt: control.learningBaselineAt, now: now
        )
    }

    /// 全部命题的权威投影（query(.active) 门闸与管理页共用同一判定）。
    func resolvedKnowledgeAll(now: Date) async throws -> [HoloResolvedKnowledge] {
        let snapshot = try await knowledgeStoreSnapshot()
        let control = try await loadControlState()
        let revisionsByProposition = Dictionary(grouping: snapshot.revisions, by: \.propositionID)
        let operationsByProposition = Dictionary(grouping: snapshot.operations, by: \.propositionID)
        var results: [HoloResolvedKnowledge] = []
        for (propositionID, revisions) in revisionsByProposition {
            let operations = operationsByProposition[propositionID] ?? []
            let resolution = HoloKnowledgeResolutionSnapshot(
                propositionID: propositionID,
                revisions: revisions,
                operations: operations,
                sourceStatus: HoloKnowledgeResolver.persistedSourceStatus(operations: operations),
                controlGeneration: control.userDecisionVersion,
                learningBaselineAt: control.learningBaselineAt,
                hasUnreadableData: snapshot.isRestrictedByDataIssues(propositionID: propositionID),
                now: now
            )
            if let resolved = HoloKnowledgeResolver.resolve(resolution) {
                results.append(resolved)
            }
        }
        return results
    }

    // MARK: 遗忘清除（09-R08：遗忘必须清除派生正文，不能只从列表隐藏）

    /// 清除该命题的知识正文与派生正文，保留最小无正文阻断（forget 操作即收据）：
    /// - 修订：revisionData 重写为无正文壳（展示/AI 正文、证据引用清空）并打 deletedAt；
    /// - 操作：纠正载荷中的用户原文、不准确理由清空（结构保留作审计收据）；
    /// - 幂等：重复执行无害。跨设备经 CloudKit 同步 deletedAt/重写数据后同样不可见。
    func purgeKnowledgeProposition(propositionID: String, now: Date) async throws {
        try await withMutationLock {
            for storage in [Storage.main, .sensitive] {
                let context = container(for: storage).newBackgroundContext()
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                try await context.perform {
                    let revisionRequest = NSFetchRequest<HoloMemoryKnowledgeRevisionMO>(
                        entityName: "HoloMemoryKnowledgeRevisionMO"
                    )
                    revisionRequest.predicate = NSPredicate(format: "propositionID == %@", propositionID)
                    for object in try context.fetch(revisionRequest) {
                        if let revision = try? Self.knowledgeDecoder().decode(HoloKnowledgeRevision.self, from: object.revisionData) {
                            var redacted = revision
                            redacted.semantic.displayText = ""
                            redacted.semantic.aiUseText = ""
                            redacted.semantic.statementDigest = nil
                            redacted.initialEvidenceSnapshot = HoloKnowledgeEvidenceSnapshot(capturedAt: revision.createdAt)
                            object.revisionData = try Self.knowledgeEncoder().encode(redacted)
                        }
                        object.deletedAt = now
                    }

                    let operationRequest = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
                        entityName: "HoloMemoryKnowledgeOperationMO"
                    )
                    operationRequest.predicate = NSPredicate(format: "propositionID == %@", propositionID)
                    for object in try context.fetch(operationRequest) {
                        guard let operation = try? Self.knowledgeDecoder().decode(HoloKnowledgeOperation.self, from: object.operationData) else { continue }
                        var redacted = operation
                        if case .correction(let newRevisionID, _) = operation.payload {
                            redacted.payload = .correction(newRevisionID: newRevisionID, statement: "")
                        }
                        if case .inaccurate(_, let scope) = operation.payload {
                            redacted.payload = .inaccurate(reason: nil, scope: scope)
                        }
                        object.operationData = try Self.knowledgeEncoder().encode(redacted)
                    }

                    if context.hasChanges {
                        do { try context.save() }
                        catch {
                            context.rollback()
                            throw HoloMemoryRepositoryError.persistenceFailed
                        }
                    }
                }
            }
        }
    }

    /// 旧记录别名 → 命题 ID（旧深链经别名解释，不跳到相似却不同的命题）。
    func knowledgePropositionIDs(alias legacyRecordID: String) async throws -> [String] {
        let snapshot = try await knowledgeStoreSnapshot()
        return snapshot.revisions
            .filter { $0.sourceAliases.contains(legacyRecordID) }
            .map(\.propositionID)
    }

    /// 遗忘清除补跑目标：存在 forget 操作、但修订正文尚未清除（deletedAt 仍为 nil）
    /// 的命题（09-R08：清除失败/中断后由启动迁移续清；幂等）。
    func pendingForgetPurgePropositionIDs() async throws -> [String] {
        var forgotten = Set<String>()
        var purged = Set<String>()
        for storage in [Storage.main, .sensitive] {
            let context = container(for: storage).newBackgroundContext()
            let ids: (forgotten: Set<String>, purged: Set<String>) = try await context.perform {
                let operationRequest = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(
                    entityName: "HoloMemoryKnowledgeOperationMO"
                )
                operationRequest.predicate = NSPredicate(format: "kind == %@", "forget")
                for object in try context.fetch(operationRequest) where !object.propositionID.isEmpty {
                    forgotten.insert(object.propositionID)
                }
                let revisionRequest = NSFetchRequest<HoloMemoryKnowledgeRevisionMO>(
                    entityName: "HoloMemoryKnowledgeRevisionMO"
                )
                revisionRequest.predicate = NSPredicate(format: "deletedAt != nil")
                for object in try context.fetch(revisionRequest) where !object.propositionID.isEmpty {
                    purged.insert(object.propositionID)
                }
                return (forgotten, purged)
            }
            forgotten.formUnion(ids.forgotten)
            purged.formUnion(ids.purged)
        }
        return forgotten.subtracting(purged).sorted()
    }

    private func knowledgeContainer(for partition: HoloKnowledgePartition) -> NSPersistentContainer {
        switch partition {
        case .normal: return controller.mainContainer
        case .sensitiveLocal: return controller.sensitiveContainer
        }
    }

    nonisolated static func knowledgeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func knowledgeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - 来源状态推导（持久化失效操作 → 当前来源状态）

extension HoloKnowledgeResolver {
    /// 来源失效是增量事件（§8 依赖：来源→证据→命题）。规则：
    /// 1. 带 refs 的操作按 ref 生效：每个 ref 取「最晚提及它的操作」的状态；
    ///    status == "verified" 是**复核回执**（真实核验过来源当前状态），清除该 ref 的失效；
    ///    不带 refs 的 verified 回执清除命题级保守失效。
    /// 2. 不带 refs 的失效操作是命题级（保守路径：远端变更/授权撤回等无法定位集合）。
    /// 3. evidenceSnapshot 刷新**只**能清除 ref 的 revised/unknown（管线重新读取过来源）；
    ///    不得清除 deleted/excluded/permissionRevoked——较晚写入的旧快照没有核验过
    ///    「用户此刻没有删除」，晚到不等于读取了较新来源（09-R11）。
    /// 4. 综合：ref 级与命题级取最严重：deleted > excluded > permissionRevoked > unknown > revised。
    static func persistedSourceStatus(
        operations: [HoloKnowledgeOperation]
    ) -> HoloKnowledgeSourceStatus {
        var refLatest: [String: (issuedAt: Date, status: String)] = [:]
        var propositionLatest: (issuedAt: Date, status: String)?
        for operation in operations.sorted(by: { $0.issuedAt < $1.issuedAt }) where operation.kind == .sourceInvalidation {
            guard case .sourceInvalidation(let refs, let status) = operation.payload else { continue }
            if status == "verified" {
                // 复核回执：真实核验过来源存在，清除命题级与对应 ref 级失效。
                propositionLatest = nil
                for ref in refs { refLatest.removeValue(forKey: ref) }
                continue
            }
            if refs.isEmpty {
                propositionLatest = (operation.issuedAt, status)
                continue
            }
            for ref in refs {
                refLatest[ref] = (operation.issuedAt, status)
            }
        }
        for operation in operations where operation.kind == .evidenceSnapshot {
            guard case .evidenceSnapshot(let snapshot) = operation.payload else { continue }
            for key in snapshot.sourceRevisions.keys {
                guard let entry = refLatest[key], entry.issuedAt < operation.issuedAt else { continue }
                // 只有「重新读取能自证」的软失效可被快照清除；删除/排除/撤权必须走复核回执。
                if entry.status == HoloKnowledgeSourceStatus.revised.rawValue
                    || entry.status == HoloKnowledgeSourceStatus.unknown.rawValue {
                    refLatest.removeValue(forKey: key)
                }
            }
        }

        var statuses = Set(refLatest.values.map(\.status))
        if let propositionLatest { statuses.insert(propositionLatest.status) }
        guard !statuses.isEmpty else { return .verified }
        for severity in ["deleted", "excluded", "permissionRevoked", "unknown", "revised"] {
            if statuses.contains(severity) {
                return HoloKnowledgeSourceStatus(rawValue: severity) ?? .unknown
            }
        }
        return .verified
    }
}
