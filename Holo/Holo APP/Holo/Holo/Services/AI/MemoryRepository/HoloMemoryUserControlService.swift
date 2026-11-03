//
//  HoloMemoryUserControlService.swift
//  Holo
//
//  用户控制统一编排服务（方案 §6 / §11.1 / M04）
//
//  组合三件地基：M03-a 语义预检（投影 allowedActions 唯一判据）+
//  M03-b 写前先行事务（事件→记录→完成标记）+ 墓碑/恢复规则（§6.1/§6.2）。
//  所有 UI 与未来消费者走这一个写入口；原 HoloMemoryFeedbackService 的
//  并行写路径在 M06/M08 收口为薄适配（本文件不改动它，两路写出的状态形状一致）。
//
//  撤销边界（如实）：确认/过时/不准确/停用可撤销（状态级可逆，§6 矩阵）；
//  「改一下」的撤销需要旧正文差异存储（M05 载荷落地后开放），当前返回 notAllowed；
//  删除不可撤销（删除确认页已明示）。
//

import Foundation

enum HoloMemoryUserControlServiceError: Error, Equatable {
    /// 请求结构非法（UI 构造错误，属开发期问题尽早暴露）。
    case malformedRequest(HoloMemoryUserControlStructuralError)
}

struct HoloMemoryUserControlService: Sendable {
    let repository: any HoloMemoryRepository
    let eventStore: HoloMemoryControlEventStore

    init(
        repository: any HoloMemoryRepository,
        eventStore: HoloMemoryControlEventStore
    ) {
        self.repository = repository
        self.eventStore = eventStore
    }

    var transaction: HoloMemoryUserControlTransaction {
        HoloMemoryUserControlTransaction(repository: repository, eventStore: eventStore)
    }

    /// 启动/进入管理页时收敛崩溃残留：按事件账本补齐未完成的控制效果。
    @discardableResult
    func reconcileOutstanding(now: Date = Date()) async throws -> Int {
        let outstanding = try await eventStore.outstandingEvents()
        return try await HoloMemoryControlEventReconciler.reconcile(
            outstanding: outstanding,
            transaction: transaction,
            repository: repository,
            now: now
        )
    }

    /// 执行一次用户控制。projection 为发起方当前所见（预检用）；
    /// 服务内部仍以仓库实时记录做版本与存在性校验（§11.3）。
    func apply(
        _ request: HoloMemoryUserControlRequest,
        projection: HoloMemoryManagementProjection?,
        now: Date = Date()
    ) async throws -> HoloMemoryUserControlOutcome {
        if let structural = request.structuralError {
            throw HoloMemoryUserControlServiceError.malformedRequest(structural)
        }
        guard var record = try await repository.fetch(id: request.recordID) else {
            return .notFound
        }
        guard record.recordVersion == request.expectedContentVersion else {
            return .conflict(currentContentVersion: record.recordVersion)
        }
        if let projection {
            let precheck = HoloMemoryUserControlRequestValidator.precheck(request, against: projection)
            if case .denied(let reason) = precheck {
                return .notAllowed(reason: reason)
            }
        }

        // 因果前驱 = 该记录全部既有事件（见过一切，供放宽判定与并发检查）。
        let priorIDs = Set((try await eventStore.events(forRecordID: record.id)).map(\.id))
        let eventID = "evt-\(UUID().uuidString)"
        let baseVersion = record.recordVersion

        switch request.action {
        case .confirm:
            record.userDecision = .confirmed
            record.state = .active
            record.confidenceScore = max(record.confidenceScore, 0.95)
            if record.adoptionMetadata == nil {
                record.adoptionMetadata = HoloMemoryAdoptionMetadata(
                    policyVersion: 1,
                    disposition: .userConfirmed,
                    reason: .explicitUserConfirmation,
                    evaluatedAt: now
                )
            }
            return try await commit(
                request, record: record, kind: .confirmed, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now
            )

        case .correct(let statement):
            record.displaySummary = statement
            record.aiUseSummary = statement
            record.personalContext?.v1?.statement = statement
            record.userDecision = .corrected
            record.state = .active
            record.recordVersion += 1
            record.predecessorVersionID = "\(record.id)@v\(baseVersion)"
            return try await commit(
                request, record: record, kind: .corrected, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now,
                digest: Self.statementDigest(statement)
            )

        case .markOutdated:
            record.state = .archived
            return try await commit(
                request, record: record, kind: .outdated, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now
            )

        case .markInaccurate(let reason):
            record.state = .suppressed
            record.userDecision = .rejected
            return try await commit(
                request, record: record, kind: .inaccurate, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now,
                digest: reason.map(Self.statementDigest)
            )

        case .disable:
            try await Self.ensureTombstone(for: record, repository: repository, now: now)
            record.state = .suppressed
            record.userDecision = .rejected
            return try await commit(
                request, record: record, kind: .disabled, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now
            )

        case .forget:
            try await Self.ensureTombstone(for: record, repository: repository, now: now)
            // 依赖该记忆的派生理解随之失效（§9.2 跨域失效），保留最小阻断墓碑。
            try await Self.invalidateDependents(of: record.id, repository: repository)
            record.state = .tombstoned
            record.userDecision = .forgotten
            // 与既有 forgotten 分支同口径：正文与证据引用一并清除（§9.2），
            // 并补全主题键/禁止推断/使用统计（逐字段审计后无残留可识别正文）。
            record.displaySummary = ""
            record.aiUseSummary = ""
            record.evidenceRefs = []
            record.counterEvidenceRefs = []
            record.personalContext = nil
            record.subjectKey = ""
            record.prohibitedInferences = []
            record.usageCount = nil
            record.lastUsedAt = nil
            return try await commit(
                request, record: record, kind: .forgotten, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now
            )

        case .restore:
            // 恢复校验链（§6.2）：先解除可逆限制（墓碑），落回事实/观察由既有决策口径决定；
            // 已过期/来源失效的记录不改归档态（进入过去桶由投影判定）。
            try await repository.clearUserControlTombstone(recordID: record.id)
            record.state = Self.rehydratedState(for: record)
            record.userDecision = .none
            return try await commit(
                request, record: record, kind: .restored, eventID: eventID,
                priorIDs: priorIDs, baseVersion: baseVersion, now: now
            )

        case .undo(let operationID):
            return try await undo(
                operationID: operationID, record: record,
                priorIDs: priorIDs, now: now
            )
        }
    }

    // MARK: - 撤销（§6.2：受控新写操作；较新控制存在时不覆盖）

    private func undo(
        operationID: String,
        record: HoloMemoryRecord,
        priorIDs: Set<String>,
        now: Date
    ) async throws -> HoloMemoryUserControlOutcome {
        guard let target = try await eventStore.event(byOperationID: operationID, recordID: record.id) else {
            return .notFound
        }
        // 只允许撤销该记录「最新一笔」操作；其后已有新控制 → 冲突，不静默覆盖（A18）。
        let latestID = try await eventStore.latestEventID(forRecordID: record.id)
        guard latestID == target.id else {
            return .conflict(currentContentVersion: record.recordVersion)
        }

        var mutated = record
        switch target.kind {
        case .confirmed:
            mutated.userDecision = .none // 撤回确认 ≠ 判错（§6）
            // 确认可能把候选晋升为 active：撤销必须退回原位（按决策口径落位，不凭空保级）。
            mutated.state = Self.rehydratedState(for: record)
        case .outdated:
            mutated.state = .active
        case .inaccurate, .disabled:
            try await repository.clearUserControlTombstone(recordID: record.id)
            mutated.state = Self.rehydratedState(for: record)
            mutated.userDecision = .none
        case .corrected:
            // 需要旧正文差异（M05 载荷）；当前如实拒绝。
            return .notAllowed(reason: .actionNotAvailable(bucket: .remembered))
        case .restored, .forgotten, .undo:
            return .notAllowed(reason: .actionNotAvailable(bucket: .remembered))
        }
        mutated.updatedAt = now

        let eventID = "evt-\(UUID().uuidString)"
        return try await commit(
            HoloMemoryUserControlRequest(
                operationID: "undo-\(operationID)-\(UUID().uuidString.prefix(8))",
                recordID: record.id,
                expectedContentVersion: record.recordVersion,
                knownControlEventIDs: priorIDs,
                action: .undo(operationID: operationID),
                issuedAt: now
            ),
            record: mutated,
            kind: .undo,
            eventID: eventID,
            priorIDs: priorIDs,
            baseVersion: record.recordVersion,
            now: now
        )
    }

    // MARK: - 落库

    private func commit(
        _ request: HoloMemoryUserControlRequest,
        record: HoloMemoryRecord,
        kind: HoloMemoryControlEventKind,
        eventID: String,
        priorIDs: Set<String>,
        baseVersion: Int,
        now: Date,
        digest: String? = nil
    ) async throws -> HoloMemoryUserControlOutcome {
        let event = HoloMemoryUserControlEvent(
            id: eventID,
            targetRecordID: record.id,
            kind: kind,
            priorEventIDs: priorIDs,
            basedOnContentVersion: baseVersion,
            resultingContentVersion: record.recordVersion,
            occurredAt: now,
            operationID: request.operationID,
            payloadDigest: digest
        )
        return try await transaction.apply(
            request: request,
            mutatedRecord: record,
            event: event,
            now: now
        )
    }

    // MARK: - 共享规则

    /// 上游记忆被删除时，依赖它的派生理解失效（进过去桶，原因=来源失效，§9.2）。
    static func invalidateDependents(
        of recordID: String,
        repository: any HoloMemoryRepository,
        now: Date = Date()
    ) async throws {
        let dependents = try await repository.query(.all).filter {
            $0.upstreamMemoryIDs.contains(recordID) && $0.state == .active
        }
        for var dependent in dependents {
            dependent.state = .invalidated
            dependent.updatedAt = now
            try await repository.replaceRecordForUserControl(dependent)
        }
    }

    /// 停用/判错/删除共用的命题墓碑（与既有 noLongerUse 路径同构，§11.6）。
    static func ensureTombstone(
        for record: HoloMemoryRecord,
        repository: any HoloMemoryRepository,
        now: Date
    ) async throws {
        let identityKey = record.id
        if try await repository.fetchTombstone(identityKey: identityKey) != nil { return }
        try await repository.saveTombstone(
            HoloMemoryTombstone(
                identityKey: identityKey,
                scope: record.scope,
                claimKind: record.claimKind,
                anchorKeys: HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).map(\.stableKey),
                userDecisionVersion: 1,
                createdAt: now
            )
        )
    }

    /// 恢复/撤销停用后的落位：事实资格 → 已记住，其余回观察（§6.2 重新校验）。
    static func rehydratedState(for record: HoloMemoryRecord) -> HoloMemoryState {
        record.decisionMetadata?.v2?.useLevel == .factEligible ? .active : .candidate
    }

    /// 陈述/原因的差异指纹（非正文存储；正文差异 M05 落地）。
    static func statementDigest(_ text: String) -> String {
        let digest = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(digest.hashValue.magnitude, radix: 36)
    }
}
