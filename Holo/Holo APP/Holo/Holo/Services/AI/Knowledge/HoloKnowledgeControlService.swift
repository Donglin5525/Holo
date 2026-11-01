//
//  HoloKnowledgeControlService.swift
//  Holo
//
//  统一知识控制（方案 v2.2 §2.4 / §3.3 / §5 / §7.1；W3）
//
//  确认绑定 propositionID + semanticDigest + 发起方见过的控制操作，而非仅 recordVersion。
//  提交时重新核对同一语义的当前证据与权限：语义改变或出现未见限制 → 明确冲突，保留草稿。
//  同分区的一次用户操作、必要新修订和收据用一个 Core Data 事务保存。
//  旧记录（别名）同步镜像用户决定，让旧消费者/旧客户端看到一致状态；新控制不写旧控制事件表。
//

import Foundation

// MARK: - 请求

nonisolated enum HoloKnowledgeControlAction: Equatable, Sendable {
    /// 符合现在的情况
    case confirm
    /// 改一下（新的用户陈述，独立来源）
    case correct(statement: String)
    /// 不准确（证据错 / 理解错 / 现在不适用）
    case markInaccurate(reason: String?, scope: HoloKnowledgeInaccurateScope)
    /// 现在不适用 → 收窄有效范围
    case narrowScope(validTo: Date)
    /// 停用
    case disable
    /// 恢复
    case restore
    /// 遗忘（正文清除，最小阻断）
    case forget
    /// 暂不处理（冷却 30 天）
    case deferCooldown
    /// 撤销最近一次操作
    indirect case undo(targetOperationID: String)

    var operationKind: HoloKnowledgeOperationKind {
        switch self {
        case .confirm: return .confirm
        case .correct: return .correct
        case .markInaccurate: return .markInaccurate
        case .narrowScope: return .narrowScope
        case .disable: return .disable
        case .restore: return .restore
        case .forget: return .forget
        case .deferCooldown: return .deferCooldown
        case .undo: return .undo
        }
    }
}

nonisolated struct HoloKnowledgeControlRequest: Equatable, Sendable {
    /// 幂等标识：重试复用同一 ID。
    let operationID: String
    let propositionID: String
    /// 发起方见到的语义指纹（确认/纠正/不准确必须带；语义已变即冲突）
    let expectedSemanticDigest: String?
    /// 发起方已见的该命题操作集合（因果校验输入）
    let knownOperationIDs: Set<String>
    let action: HoloKnowledgeControlAction
    /// 发起入口（memoryCenter / discovery），用于共同提示记录
    let entry: String
    let issuedAt: Date

    init(
        operationID: String = UUID().uuidString,
        propositionID: String,
        expectedSemanticDigest: String?,
        knownOperationIDs: Set<String>,
        action: HoloKnowledgeControlAction,
        entry: String,
        issuedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.propositionID = propositionID
        self.expectedSemanticDigest = expectedSemanticDigest
        self.knownOperationIDs = knownOperationIDs
        self.action = action
        self.entry = entry
        self.issuedAt = issuedAt
    }
}

nonisolated enum HoloKnowledgeControlOutcome: Equatable, Sendable {
    case applied(propositionID: String, undoableOperationID: String?)
    case alreadyApplied
    /// 语义已变化或出现未见限制：保留草稿，提示查看新版本
    case conflict(currentSemanticDigest: String?, reason: String)
    case notFound
    case notAllowed(reason: String)
    case persistenceFailed(description: String)

    var isSuccess: Bool {
        switch self {
        case .applied, .alreadyApplied: return true
        case .conflict, .notFound, .notAllowed, .persistenceFailed: return false
        }
    }
}

// MARK: - 服务

extension Notification.Name {
    /// 知识控制已生效：userInfo["propositionID"], ["kind"]（发现侧据此撤下引用旧语义的发现）
    static let holoKnowledgeControlDidApply = Notification.Name("holoKnowledgeControlDidApply")
}

final class HoloKnowledgeControlService: Sendable {
    static let cooldownInterval: TimeInterval = 30 * 86_400

    private let repository: CoreDataHoloMemoryRepository

    init(repository: CoreDataHoloMemoryRepository) {
        self.repository = repository
    }

    func apply(_ request: HoloKnowledgeControlRequest) async throws -> HoloKnowledgeControlOutcome {
        guard !request.operationID.isEmpty, !request.propositionID.isEmpty else {
            return .notAllowed(reason: "structuralInvalid")
        }
        if case .correct(let statement) = request.action,
           statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notAllowed(reason: "emptyCorrection")
        }

        // 幂等：同 operationID 已存在 = 重试成功。但重试路径也要补齐此前可能
        // 失败的镜像与控制代数推进（09-R09：失败不假成功；重试幂等收敛）。
        // 语义效果核验（2026-10-31 审计 E2）：发现侧用确定性 operationID（disc-save-/disc-defer-），
        // 冷却到期后再点「暂时不说」、确认后命题又被停用/否定后再点「确认并记住」，
        // 都是**新一轮用户决策**——原操作行虽在、语义效果已不成立，不能当重试成功。
        // 此时落 #N 后缀新代操作重走完整校验（冲突时如实返回冲突，不假成功）。
        if try await repository.knowledgeOperation(operationID: request.operationID) != nil {
            if try await semanticEffectStillHolds(request) {
                await completeMirroring(request: request, snapshot: nil)
                return .alreadyApplied
            }
            var generation = 1
            while try await repository.knowledgeOperation(operationID: "\(request.operationID)#\(generation)") != nil {
                generation += 1
            }
            return try await apply(HoloKnowledgeControlRequest(
                operationID: "\(request.operationID)#\(generation)",
                propositionID: request.propositionID,
                expectedSemanticDigest: request.expectedSemanticDigest,
                knownOperationIDs: request.knownOperationIDs,
                action: request.action,
                entry: request.entry,
                issuedAt: request.issuedAt
            ))
        }

        let now = request.issuedAt
        let snapshot = try await repository.knowledgeStoreSnapshot(propositionID: request.propositionID)
        guard let latest = snapshot.revisions.max(by: { $0.createdAt < $1.createdAt }) else {
            // 没有修订的命题（如发现里尚未保存的 claim）：限制/暂缓类操作可独立落库——
            // 用户的明确否定与「暂不处理」是权威控制事实，不依赖正文存在（融合契约 §5；D05/D18）。
            // 放宽类（确认/纠正/恢复）必须有可绑定的语义修订。
            switch request.action {
            case .markInaccurate, .narrowScope, .deferCooldown:
                return try await applyStandaloneRestriction(request, snapshot: snapshot, now: now)
            case .restore:
                // 已清除正文的遗忘命题：恢复不可解除遗忘（08 §4.5），但因果语义
                // 仍要成立——未见限制的恢复返回冲突，不能因正文已清当作
                // 「命题不存在」（notFound 会让调用方误判状态未知）。
                let forgetOps = snapshot.operations.filter { $0.kind == .forget }
                if !forgetOps.isEmpty {
                    let unseen = forgetOps.contains { !request.knownOperationIDs.contains($0.operationID) }
                    return unseen
                        ? .conflict(currentSemanticDigest: nil, reason: "unseenRestriction")
                        : .notAllowed(reason: "forgetNotRestorable")
                }
                return .notFound
            case .confirm, .correct, .disable, .forget, .undo:
                return .notFound
            }
        }
        guard let resolved = try await repository.resolvedKnowledge(propositionID: request.propositionID, now: now) else {
            return .notFound
        }
        let control = try await repository.loadControlState()
        let partition = latest.partition

        // 因果校验：发起方必须见过全部当前限制，否则不得放宽（限制优先）。
        let unseenRestrictions = resolved.restrictingOperationIDs.subtracting(request.knownOperationIDs)
        switch request.action {
        case .confirm, .correct, .restore, .undo:
            if !unseenRestrictions.isEmpty {
                return .conflict(currentSemanticDigest: latest.semanticDigest, reason: "unseenRestriction")
            }
        case .markInaccurate, .narrowScope, .disable, .forget, .deferCooldown:
            break
        }

        // 语义核对：确认/纠正/不准确绑定发起方见到的语义指纹。
        let targetDigest: String
        switch request.action {
        case .confirm, .correct, .markInaccurate, .deferCooldown:
            guard let expected = request.expectedSemanticDigest else {
                return .notAllowed(reason: "missingSemanticDigest")
            }
            guard snapshot.revisions.contains(where: { $0.semanticDigest == expected }) else {
                return .conflict(currentSemanticDigest: latest.semanticDigest, reason: "semanticChanged")
            }
            if request.action.operationKind == .confirm, expected != latest.semanticDigest {
                // 只能确认当前最新建议版本；更早版本的确认不隐含认可新版本。
                return .conflict(currentSemanticDigest: latest.semanticDigest, reason: "newerRevisionExists")
            }
            targetDigest = expected
        case .narrowScope, .disable, .restore, .forget, .undo:
            targetDigest = request.expectedSemanticDigest ?? latest.semanticDigest
        }
        let targetRevision = snapshot.revisions.first { $0.semanticDigest == targetDigest } ?? latest

        // 确认前提：行为归纳只能在成熟（值得确认）时确认；直接陈述/来源关联无需确认。
        if request.action.operationKind == .confirm {
            switch resolved.decision {
            case .worthConfirming, .remembered, .confirmedValid:
                break
            case .noValue, .internalAccumulating:
                return .notAllowed(reason: "notMature")
            case .inactive:
                return .notAllowed(reason: "inactive")
            }
        }
        if request.action.operationKind == .undo {
            guard let undoable = resolved.undoableOperationID,
                  case .undo(let target) = request.action, target == undoable else {
                return .notAllowed(reason: "undoNotLatest")
            }
            if let targetOp = snapshot.operations.first(where: { $0.operationID == undoable }),
               [.forget, .correct, .restore, .undo].contains(targetOp.kind) {
                return .notAllowed(reason: "undoNotSupportedForKind")
            }
        }

        // 构造操作（必要时新修订）。
        let priors = request.knownOperationIDs.union(Set(snapshot.operations.map(\.operationID)))
        var newRevision: HoloKnowledgeRevision?
        let payload: HoloKnowledgeOperationPayload
        switch request.action {
        case .confirm:
            let snapshotID = resolved.latestEvidenceSnapshot?.id ?? targetRevision.initialEvidenceSnapshot.id
            payload = .confirmation(semanticDigest: targetDigest, evidenceSnapshotID: snapshotID)
        case .correct(let statement):
            var semantic = targetRevision.semantic
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            semantic.displayText = trimmed
            semantic.aiUseText = trimmed
            semantic.formation = .userCorrection
            semantic.evidenceForm = .explicitSemanticFact
            // 用户陈述是独立语义来源：其规范化指纹参与 semanticDigest（09-R02）。
            // 不带它的旧实现里纠正只改文案 → 指纹不变 → 新修订与旧修订同 ID
            // → 被 upsert 幂等吞掉，纠正从未真正入库。
            semantic.statementDigest = HoloKnowledgeIdentity.fnv1a64(
                HoloKnowledgeIdentity.normalize(trimmed)
            )
            // 用户新陈述是独立来源：以用户原话为证据；不制造行为次数。
            let statementRef = HoloMemoryEvidenceRef(
                id: "correction-\(request.operationID)",
                kind: .explicitUserStatement,
                sourceDomain: targetRevision.domains.first ?? .conversation,
                lineageKey: "user-correction:\(request.operationID)",
                sourceID: request.operationID,
                revisionDigest: HoloKnowledgeIdentity.fnv1a64(semantic.displayText),
                observedAt: now,
                summary: semantic.displayText
            )
            let evidence = HoloKnowledgeEvidenceSnapshot(
                supportRefs: [statementRef],
                independentEventCount: 1,
                counterexampleSearch: .notSearched,
                sourceRevisions: [statementRef.lineageKey: statementRef.revisionDigest],
                capturedAt: now
            )
            let revision = HoloKnowledgeRevision.make(
                semantic: semantic,
                topicLabel: targetRevision.topicLabel,
                domains: targetRevision.domains,
                sensitivity: targetRevision.sensitivity,
                partition: partition,
                evidenceSnapshot: evidence,
                sourceAliases: targetRevision.sourceAliases,
                origin: HoloKnowledgeOrigin(kind: .userStatement, producer: request.entry),
                predecessorRevisionID: targetRevision.semanticRevisionID,
                createdAt: now
            )
            newRevision = revision
            payload = .correction(newRevisionID: revision.semanticRevisionID, statement: semantic.displayText)
        case .markInaccurate(let reason, let scope):
            payload = .inaccurate(reason: reason, scope: scope)
        case .narrowScope(let validTo):
            payload = .narrowing(validTo: validTo)
        case .disable, .restore, .forget:
            payload = .none
        case .deferCooldown:
            payload = .cooldown(until: now.addingTimeInterval(Self.cooldownInterval))
        case .undo(let targetOperationID):
            payload = .undo(targetOperationID: targetOperationID)
        }

        let operation = HoloKnowledgeOperation(
            operationID: request.operationID,
            kind: request.action.operationKind,
            propositionID: request.propositionID,
            targetSemanticRevisionID: newRevision?.semanticRevisionID ?? targetRevision.semanticRevisionID,
            targetSemanticDigest: newRevision?.semanticDigest ?? targetDigest,
            priorOperationIDs: priors,
            controlGeneration: control.userDecisionVersion + 1,
            payload: payload,
            partition: partition,
            issuedAt: now
        )

        // 共同提示记录：确认/暂缓在哪个入口完成（避免同版本跨入口重复询问）。
        var operations = [operation]
        if request.action.operationKind == .confirm || request.action.operationKind == .deferCooldown {
            operations.append(HoloKnowledgeOperation(
                operationID: "prompt-\(request.operationID)",
                kind: .promptRecord,
                propositionID: request.propositionID,
                targetSemanticDigest: targetDigest,
                priorOperationIDs: [request.operationID],
                controlGeneration: control.userDecisionVersion + 1,
                payload: .promptRecord(
                    entry: request.entry,
                    semanticDigest: targetDigest,
                    outcome: request.action.operationKind == .confirm ? "saved" : "deferred"
                ),
                partition: partition,
                issuedAt: now
            ))
        }

        do {
            try await repository.saveKnowledgeRevisionAndOperation(revision: newRevision, operations: operations)
        } catch {
            return .persistenceFailed(description: String(describing: error))
        }

        // 遗忘清除链（09-R08）：forget 操作落库（已停用）后清除正文与派生正文；
        // 清除失败不回滚停用——上层显示「已停用，正在清除」，启动补跑会续清。
        if request.action.operationKind == .forget {
            do {
                try await repository.purgeKnowledgeProposition(propositionID: request.propositionID, now: now)
            } catch {
                NSLog("[HoloKnowledge] 遗忘清除未完成（将启动补跑）: \(request.propositionID) \(error)")
            }
        }

        return await completeMirroring(request: request, snapshot: snapshot)
    }

    // MARK: 收尾：控制代数推进 + 旧别名镜像（成功与幂等重试共用，09-R09/R10）

    private func completeMirroring(
        request: HoloKnowledgeControlRequest,
        snapshot: HoloKnowledgeStoreSnapshot?
    ) async -> HoloKnowledgeControlOutcome {
        let now = request.issuedAt

        // 控制代数推进（跨设备单调）。失败返回 persistenceFailed：知识操作已保存，
        // 用户重试会命中幂等分支并回到这里补齐——不吞错、不假成功。
        do {
            let control = try await repository.loadControlState()
            var nextControl = control
            nextControl.userDecisionVersion += 1
            nextControl.updatedAt = now
            try await repository.saveControlState(nextControl)
        } catch {
            return .persistenceFailed(description: "controlState: \(String(describing: error))")
        }

        // 旧记录别名镜像：旧消费者/旧客户端看到一致的用户决定；不写旧控制事件表。
        // 纠正镜像为 rejected 而非 corrected（09-R10）：旧端对 corrected 的行为是
        // 置 active 并抬置信度但沿用旧正文——纠正的正确旧端语义是「旧含义停用」，
        // 新含义只存在于新知识表。幂等重试分支未带 snapshot 时现查。
        var mirrorSnapshot = snapshot
        if mirrorSnapshot == nil {
            mirrorSnapshot = try? await repository.knowledgeStoreSnapshot(propositionID: request.propositionID)
        }
        if let mirrorSnapshot {
            await mirrorToLegacyAliases(
                aliases: Set(mirrorSnapshot.revisions.flatMap(\.sourceAliases)),
                action: request.action,
                now: now
            )
        }

        NotificationCenter.default.post(
            name: .holoKnowledgeControlDidApply,
            object: nil,
            userInfo: [
                "propositionID": request.propositionID,
                "kind": request.action.operationKind.rawValue,
                "semanticDigest": request.expectedSemanticDigest ?? "",
            ]
        )

        let undoable: String? = [.confirm, .markInaccurate, .narrowScope, .disable, .deferCooldown]
            .contains(request.action.operationKind) ? request.operationID : nil
        return .applied(propositionID: request.propositionID, undoableOperationID: undoable)
    }

    // MARK: 无修订命题的独立限制（发现未保存 claim 的最低否定 / 暂缓）

    /// 幂等命中的语义效果核验（2026-10-31 审计 E2）：
    /// 操作行存在 ≠ 效果仍在。只核验时间有界/可被后续操作推翻的两类——
    /// deferCooldown（冷却可能已过期）与 confirm（确认后可能又被停用/否定）；
    /// 其余限制类操作落库即长期有效（解除走 restore/undo 的新 operationID），行在即效果在。
    private func semanticEffectStillHolds(_ request: HoloKnowledgeControlRequest) async throws -> Bool {
        let now = request.issuedAt
        let snapshot = try await repository.knowledgeStoreSnapshot(propositionID: request.propositionID)
        switch request.action.operationKind {
        case .deferCooldown:
            return snapshot.operations.contains { operation in
                guard operation.kind == .deferCooldown,
                      case .cooldown(let until) = operation.payload else { return false }
                return until > now
            }
        case .confirm:
            guard let resolved = try await repository.resolvedKnowledge(propositionID: request.propositionID, now: now) else {
                return false
            }
            return resolved.decision.isUsableForAnswering
        default:
            return true
        }
    }

    private func applyStandaloneRestriction(
        _ request: HoloKnowledgeControlRequest,
        snapshot: HoloKnowledgeStoreSnapshot,
        now: Date
    ) async throws -> HoloKnowledgeControlOutcome {
        let payload: HoloKnowledgeOperationPayload
        switch request.action {
        case .markInaccurate(let reason, let scope): payload = .inaccurate(reason: reason, scope: scope)
        case .narrowScope(let validTo): payload = .narrowing(validTo: validTo)
        case .deferCooldown: payload = .cooldown(until: now.addingTimeInterval(Self.cooldownInterval))
        default: return .notFound
        }
        let control = try await repository.loadControlState()
        var operations = [HoloKnowledgeOperation(
            operationID: request.operationID,
            kind: request.action.operationKind,
            propositionID: request.propositionID,
            targetSemanticDigest: request.expectedSemanticDigest,
            priorOperationIDs: Set(snapshot.operations.map(\.operationID)),
            controlGeneration: control.userDecisionVersion + 1,
            payload: payload,
            partition: .normal,
            issuedAt: now
        )]
        if request.action.operationKind == .deferCooldown, let digest = request.expectedSemanticDigest {
            operations.append(HoloKnowledgeOperation(
                operationID: "prompt-\(request.operationID)",
                kind: .promptRecord,
                propositionID: request.propositionID,
                targetSemanticDigest: digest,
                priorOperationIDs: [request.operationID],
                controlGeneration: control.userDecisionVersion + 1,
                payload: .promptRecord(entry: request.entry, semanticDigest: digest, outcome: "deferred"),
                partition: .normal,
                issuedAt: now
            ))
        }
        do {
            try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: operations)
        } catch {
            return .persistenceFailed(description: String(describing: error))
        }
        NotificationCenter.default.post(
            name: .holoKnowledgeControlDidApply,
            object: nil,
            userInfo: [
                "propositionID": request.propositionID,
                "kind": request.action.operationKind.rawValue,
                "semanticDigest": request.expectedSemanticDigest ?? "",
            ]
        )
        return .applied(propositionID: request.propositionID, undoableOperationID: nil)
    }

    // MARK: 旧记录镜像

    private func mirrorToLegacyAliases(
        aliases: Set<String>,
        action: HoloKnowledgeControlAction,
        now: Date
    ) async {
        guard !aliases.isEmpty else { return }
        let decision: HoloMemoryUserDecision?
        switch action {
        case .confirm: decision = .confirmed
        // 纠正镜像为 rejected：旧端「corrected=激活+抬置信度+沿用旧正文」会让
        // 被纠正的旧含义继续以高可信使用（09-R10）；旧含义必须先停用。
        case .correct: decision = .rejected
        case .markInaccurate, .disable: decision = .rejected
        case .forget: decision = .forgotten
        case .narrowScope, .deferCooldown, .restore, .undo: decision = nil
        }
        guard let decision else { return }
        for alias in aliases {
            _ = try? await repository.markUserDecision(id: alias, decision: decision, now: now)
        }
    }
}
