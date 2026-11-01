//
//  HoloKnowledgeMigrationEngine.swift
//  Holo
//
//  历史迁移（方案 v2.2 §7.2 存量分流 / §7.3 分批迁移 / §7.5 旧写入与晚到）
//
//  先读控制与基线 → 分类旧记录 → 生成别名映射 → 写入新知识 → 校验分区 → 标记单项完成。
//  每个处理键 = 旧 ID + 策略版本；收据与修订/操作同事务生效；游标只在持久化成功后推进；
//  重复执行不重复确认或新增知识。不以本机 UserDefaults 单个完成标志代表全账户完成
//  ——收据存在知识操作表中，随分区同步/留本机，换设备/换 Store 以收据为准。
//  不准确/停用/遗忘/墓碑先导入阻断；旧 active 不等于已认可；自动单次流水退出主记忆。
//  仍在运行的旧客户端写入旧格式 → 新端把它作为待分类输入（下次迁移批次），不是权威覆盖。
//

import Foundation

final class HoloKnowledgeMigrationEngine: Sendable {
    /// v2（2026-11-01）：读取端 formation 防线（错标 explicitUserStatement 只认
    /// 对话域、业务域 declared 降级）后的复评版——上一版被当「有价值」导入的
    /// 旧命题，若新分类口径下属自动类，写 legacyRetire 操作退出当前理解。
    static let policyVersion = 2
    /// 单批上限（预算受控；重复执行续跑）
    static let defaultBatchLimit = 400

    nonisolated struct Report: Equatable, Sendable {
        var scanned = 0
        var committed = 0
        var restricted = 0
        var exited = 0
        var blocked = 0
        var alreadyProcessed = 0
        /// 本批未处理完（达到 batchLimit），需要再跑
        var hasMore = false
    }

    private let repository: CoreDataHoloMemoryRepository

    init(repository: CoreDataHoloMemoryRepository) {
        self.repository = repository
    }

    func run(now: Date = Date(), batchLimit: Int = HoloKnowledgeMigrationEngine.defaultBatchLimit) async throws -> Report {
        var report = Report()
        let receipts = try await repository.knowledgeMigrationReceipts(policyVersion: Self.policyVersion)
        let control = try await repository.loadControlState()
        let records = try await repository.query(.all)
        // 复评反查：本版之前各策略版本导入过的命题（v2 起；v1 无此需求时为空开销）。
        let priorVersions = Array(1..<Self.policyVersion)
        let priorImports: [String: Set<String>] = priorVersions.isEmpty
            ? [:]
            : (try await repository.knowledgeImportedPropositions(
                legacyRecordIDs: records.map(\.id),
                policyVersions: priorVersions
            ))

        // 控制优先：阻断类先导入，再用户陈述/已确认，再其余（§7.3）。
        let ordered = records.sorted { lhs, rhs in
            let l = Self.priority(HoloKnowledgeLegacyAdapter.classify(lhs))
            let r = Self.priority(HoloKnowledgeLegacyAdapter.classify(rhs))
            if l != r { return l < r }
            return lhs.id < rhs.id
        }

        var processedThisBatch = 0
        for record in ordered {
            let processingKey = HoloKnowledgeMigrationReceipt.makeProcessingKey(
                legacyRecordID: record.id,
                policyVersion: Self.policyVersion
            )
            if let existing = receipts[processingKey], existing.legacyRecordVersion >= record.recordVersion {
                report.alreadyProcessed += 1
                continue
            }
            if processedThisBatch >= batchLimit {
                report.hasMore = true
                break
            }
            processedThisBatch += 1
            report.scanned += 1

            let classification = HoloKnowledgeLegacyAdapter.classify(record)
            let partition = HoloKnowledgePartitionPolicy.partition(for: record)
            var receipt = HoloKnowledgeMigrationReceipt(
                processingKey: processingKey,
                legacyRecordID: record.id,
                legacyRecordVersion: record.recordVersion,
                policyVersion: Self.policyVersion,
                partition: partition,
                status: .scanned,
                completedAt: now
            )

            switch classification {
            case .blocked:
                // 原因与阻断范围先导入：有正文的被拒记录建修订并标不准确；遗忘记录（正文已清）
                // 只保留收据——不从摘要重建已删正文（§7.5）。
                let outcome = try await importBlocked(record: record, partition: partition, control: control, now: now)
                receipt.status = outcome == nil ? .restricted : .committed
                receipt.propositionID = outcome
                receipt.detail = "blocked:\(record.userDecision.rawValue)/\(record.state.rawValue)"
                report.blocked += 1

            case .reliableUserStatement, .confirmedPattern, .confirmedSingleEvent:
                let outcome = try await importValued(record: record, classification: classification, partition: partition, control: control, now: now)
                receipt.status = outcome == nil ? .restricted : .committed
                receipt.propositionID = outcome
                receipt.detail = classification.rawValue
                if outcome == nil { report.restricted += 1 } else { report.committed += 1 }

            case .autoInferenceUnconfirmed:
                // 有原始支持才进通用聚合与成熟度检查；不因旧 active 自动当已认可。
                let outcome = try await importInference(record: record, partition: partition, control: control, now: now)
                receipt.status = outcome == nil ? .restricted : .committed
                receipt.propositionID = outcome
                receipt.detail = classification.rawValue
                if outcome == nil { report.restricted += 1 } else { report.committed += 1 }

            case .autoLowValue:
                receipt.status = .exited
                receipt.detail = classification.rawValue
                report.exited += 1

            case .unresolvable:
                receipt.status = .restricted
                receipt.detail = classification.rawValue
                report.restricted += 1
            }

            // 复评退役（v2）：本分支没有产出新命题、而旧策略版本曾把它当
            // 有价值导入过 → 旧命题写 legacyRetire，退出当前理解（保留历史）。
            var retireOperations: [HoloKnowledgeOperation] = []
            if receipt.propositionID == nil, let priors = priorImports[record.id], !priors.isEmpty {
                retireOperations = priors.sorted().map { propositionID in
                    HoloKnowledgeOperation(
                        operationID: "legacy-retire-\(record.id)-\(propositionID)-p\(Self.policyVersion)",
                        kind: .legacyRetire,
                        propositionID: propositionID,
                        controlGeneration: control.userDecisionVersion,
                        payload: .none,
                        partition: partition,
                        issuedAt: now
                    )
                }
                receipt.detail = "\(receipt.detail)|retired:\(priors.count)"
            }

            try await repository.saveKnowledgeRevisionAndOperation(
                revision: nil,
                operations: [HoloKnowledgeOperation(
                    operationID: "receipt-\(processingKey)-v\(record.recordVersion)",
                    kind: .migrationReceipt,
                    propositionID: receipt.propositionID ?? "legacy:\(record.id)",
                    controlGeneration: control.userDecisionVersion,
                    payload: .migrationReceipt(receipt),
                    partition: partition,
                    issuedAt: now
                )] + retireOperations
            )
        }
        return report
    }

    // MARK: 导入分支

    /// 有价值的旧记录：走统一准入（同一映射）；已确认者补绑定原语义的确认操作。
    private func importValued(
        record: HoloMemoryRecord,
        classification: HoloKnowledgeLegacyClassification,
        partition: HoloKnowledgePartition,
        control: HoloMemoryControlState,
        now: Date
    ) async throws -> String? {
        guard let assessment = HoloKnowledgeIngestion.assessment(from: record, persistenceAuthorized: true, now: now) else {
            return nil
        }
        var semantic = assessment.semantic
        // 已确认的单次事件：保留确认与历史，不扩成持续属性（§7.2）。
        if classification == .confirmedSingleEvent, case .ongoing = semantic.applicability.windowRule {
            semantic.applicability = HoloKnowledgeApplicability(
                windowRule: .absolute(from: record.validFrom ?? record.createdAt, to: record.validTo ?? record.updatedAt),
                conditionText: semantic.applicability.conditionText,
                exceptions: semantic.applicability.exceptions
            )
        }
        let revision = HoloKnowledgeRevision.make(
            semantic: semantic,
            topicLabel: HoloKnowledgeIngestion.topicLabel(for: record),
            domains: assessment.domains,
            sensitivity: assessment.sensitivity,
            partition: partition,
            evidenceSnapshot: assessment.evidenceSnapshot,
            sourceAliases: [record.id],
            origin: HoloKnowledgeOrigin(kind: .legacyRecord, legacyRecordID: record.id, producer: "knowledgeMigration"),
            createdAt: record.createdAt
        )
        var operations: [HoloKnowledgeOperation] = [
            HoloKnowledgeOperation(
                operationID: "alias-\(record.id)-p\(Self.policyVersion)",
                kind: .aliasImport,
                propositionID: revision.propositionID,
                targetSemanticRevisionID: revision.semanticRevisionID,
                targetSemanticDigest: revision.semanticDigest,
                controlGeneration: control.userDecisionVersion,
                payload: .aliasImport(legacyRecordID: record.id, legacyUserDecision: record.userDecision.rawValue),
                partition: partition,
                issuedAt: now
            ),
        ]
        if record.userDecision == .confirmed || record.userDecision == .corrected {
            // 原确认只适用原命题/原语义：绑定本修订指纹（§7.2 / C01）。
            operations.append(HoloKnowledgeOperation(
                operationID: "legacy-confirm-\(record.id)-\(revision.semanticDigest)",
                kind: .confirm,
                propositionID: revision.propositionID,
                targetSemanticRevisionID: revision.semanticRevisionID,
                targetSemanticDigest: revision.semanticDigest,
                priorOperationIDs: [],
                controlGeneration: control.userDecisionVersion,
                payload: .confirmation(semanticDigest: revision.semanticDigest, evidenceSnapshotID: revision.initialEvidenceSnapshot.id),
                partition: partition,
                issuedAt: record.updatedAt
            ))
        }
        try await repository.saveKnowledgeRevisionAndOperation(revision: revision, operations: operations)
        return revision.propositionID
    }

    /// 自动归纳未确认：有原始支持才建修订（准入通过才写），不继承认可。
    private func importInference(
        record: HoloMemoryRecord,
        partition: HoloKnowledgePartition,
        control: HoloMemoryControlState,
        now: Date
    ) async throws -> String? {
        guard let assessment = HoloKnowledgeIngestion.assessment(from: record, persistenceAuthorized: true, now: now) else {
            return nil
        }
        let verdict = HoloKnowledgeAdmission.assess(
            semantic: assessment.semantic,
            evidence: assessment.evidenceSnapshot,
            authorizedSourceDomains: assessment.authorizedSourceDomains
        )
        switch verdict {
        case .reject, .internalOnly:
            return nil
        case .remembered, .worthConfirming:
            break
        }
        let revision = HoloKnowledgeRevision.make(
            semantic: assessment.semantic,
            topicLabel: HoloKnowledgeIngestion.topicLabel(for: record),
            domains: assessment.domains,
            sensitivity: assessment.sensitivity,
            partition: partition,
            evidenceSnapshot: assessment.evidenceSnapshot,
            sourceAliases: [record.id],
            origin: HoloKnowledgeOrigin(kind: .legacyRecord, legacyRecordID: record.id, producer: "knowledgeMigration"),
            createdAt: record.createdAt
        )
        try await repository.saveKnowledgeRevisionAndOperation(
            revision: revision,
            operations: [HoloKnowledgeOperation(
                operationID: "alias-\(record.id)-p\(Self.policyVersion)",
                kind: .aliasImport,
                propositionID: revision.propositionID,
                targetSemanticRevisionID: revision.semanticRevisionID,
                targetSemanticDigest: revision.semanticDigest,
                controlGeneration: control.userDecisionVersion,
                payload: .aliasImport(legacyRecordID: record.id, legacyUserDecision: record.userDecision.rawValue),
                partition: partition,
                issuedAt: now
            )]
        )
        return revision.propositionID
    }

    /// 阻断类：被拒绝（有正文）→ 修订 + markInaccurate；遗忘/墓碑（无正文）→ 仅收据。
    private func importBlocked(
        record: HoloMemoryRecord,
        partition: HoloKnowledgePartition,
        control: HoloMemoryControlState,
        now: Date
    ) async throws -> String? {
        guard let assessment = HoloKnowledgeIngestion.assessment(from: record, persistenceAuthorized: true, now: now) else {
            return nil
        }
        let revision = HoloKnowledgeRevision.make(
            semantic: assessment.semantic,
            topicLabel: HoloKnowledgeIngestion.topicLabel(for: record),
            domains: assessment.domains,
            sensitivity: assessment.sensitivity,
            partition: partition,
            evidenceSnapshot: assessment.evidenceSnapshot,
            sourceAliases: [record.id],
            origin: HoloKnowledgeOrigin(kind: .legacyRecord, legacyRecordID: record.id, producer: "knowledgeMigration"),
            createdAt: record.createdAt
        )
        let restriction: HoloKnowledgeOperation
        if record.userDecision == .forgotten || record.state == .tombstoned {
            restriction = HoloKnowledgeOperation(
                operationID: "legacy-forget-\(record.id)",
                kind: .forget,
                propositionID: revision.propositionID,
                targetSemanticRevisionID: revision.semanticRevisionID,
                targetSemanticDigest: revision.semanticDigest,
                controlGeneration: control.userDecisionVersion,
                payload: .none,
                partition: partition,
                issuedAt: record.updatedAt
            )
        } else {
            restriction = HoloKnowledgeOperation(
                operationID: "legacy-inaccurate-\(record.id)-\(revision.semanticDigest)",
                kind: .markInaccurate,
                propositionID: revision.propositionID,
                targetSemanticRevisionID: revision.semanticRevisionID,
                targetSemanticDigest: revision.semanticDigest,
                controlGeneration: control.userDecisionVersion,
                payload: .inaccurate(reason: "legacy:\(record.userDecision.rawValue)", scope: .understanding),
                partition: partition,
                issuedAt: record.updatedAt
            )
        }
        try await repository.saveKnowledgeRevisionAndOperation(
            revision: revision,
            operations: [
                HoloKnowledgeOperation(
                    operationID: "alias-\(record.id)-p\(Self.policyVersion)",
                    kind: .aliasImport,
                    propositionID: revision.propositionID,
                    targetSemanticRevisionID: revision.semanticRevisionID,
                    targetSemanticDigest: revision.semanticDigest,
                    controlGeneration: control.userDecisionVersion,
                    payload: .aliasImport(legacyRecordID: record.id, legacyUserDecision: record.userDecision.rawValue),
                    partition: partition,
                    issuedAt: now
                ),
                restriction,
            ]
        )
        return revision.propositionID
    }

    private static func priority(_ classification: HoloKnowledgeLegacyClassification) -> Int {
        switch classification {
        case .blocked: return 0
        case .reliableUserStatement: return 1
        case .confirmedPattern, .confirmedSingleEvent: return 2
        case .autoInferenceUnconfirmed: return 3
        case .autoLowValue, .unresolvable: return 4
        }
    }
}
