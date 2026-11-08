//
//  HoloKnowledgeResolver.swift
//  Holo
//
//  统一解析器（方案 v2.2 §2.4 / §3.3 / §4）
//
//  由修订 + 操作 + 来源状态 + 控制基线投影出唯一权威的 HoloResolvedKnowledge。
//  复用既有控制代数语义：限制优先、未见限制不得被解除、两次纠正保持冲突、
//  不比较时间戳。确认绑定 semanticDigest；新语义修订不继承旧确认。
//

import Foundation

// MARK: - 解析输入快照

nonisolated struct HoloKnowledgeResolutionSnapshot: Sendable {
    var propositionID: String
    var revisions: [HoloKnowledgeRevision]
    var operations: [HoloKnowledgeOperation]
    var sourceStatus: HoloKnowledgeSourceStatus
    var controlGeneration: Int64
    var learningBaselineAt: Date?
    /// 存在不可读行或同 ID 内容冲突（09-R06/R07）：解析器对整个命题保守限制。
    var hasUnreadableData: Bool
    var now: Date

    init(
        propositionID: String,
        revisions: [HoloKnowledgeRevision],
        operations: [HoloKnowledgeOperation],
        sourceStatus: HoloKnowledgeSourceStatus = .notVerifiedUsageNeutral,
        controlGeneration: Int64 = 0,
        learningBaselineAt: Date? = nil,
        hasUnreadableData: Bool = false,
        now: Date
    ) {
        self.propositionID = propositionID
        self.revisions = revisions.sorted { $0.createdAt < $1.createdAt }
        self.operations = operations.sorted { $0.issuedAt < $1.issuedAt }
        self.sourceStatus = sourceStatus
        self.controlGeneration = controlGeneration
        self.learningBaselineAt = learningBaselineAt
        self.hasUnreadableData = hasUnreadableData
        self.now = now
    }
}

/// 直接陈述/用户纠正的证据是独立来源：来源失效不阻断（§4「来源核验」）。
/// sourceLinked / behavioralInference 的证据来源失效即停用当前用途。
extension HoloKnowledgeSourceStatus {
    /// 尚未核验（历史数据/未接线来源）：对 sourceLinked/inference 阻断，对直接陈述不阻断。
    static let notVerifiedUsageNeutral = HoloKnowledgeSourceStatus.unknown
}

// MARK: - 解析器

nonisolated enum HoloKnowledgeResolver {

    /// 命题 → 唯一权威投影。空快照（无修订）返回 nil：命题不存在，不猜测。
    /// 例外：无修订但存在 forget 操作 → 返回最小无正文阻断（遗忘清除后的常态：
    /// 修订正文已清、只剩阻断收据；命题是「已遗忘」不是「不存在」，深链/管理页
    /// 仍可解释状态）。
    static func resolve(_ snapshot: HoloKnowledgeResolutionSnapshot) -> HoloResolvedKnowledge? {
        guard let latest = snapshot.revisions.last else {
            if snapshot.operations.contains(where: { $0.kind == .forget }) {
                return makeResolved(
                    snapshot: snapshot,
                    latest: nil,
                    proposed: nil,
                    confirmedDigest: nil,
                    decision: .inactive,
                    reasons: ["forgotten"],
                    uses: [],
                    restrictionIDs: Set(
                        snapshot.operations
                            .filter(\.kind.isUsageRestricting)
                            .map(\.operationID)
                    ),
                    formation: .userCorrection,
                    undoableOperationID: nil
                )
            }
            return nil
        }

        // 1. 撤销：仅最近一次用户操作可撤销（与既有 M04 口径一致）。
        var effectiveOperations = snapshot.operations
        if let undoOp = snapshot.operations.last(where: { $0.kind == .undo }),
           isLatestUserOperation(undoOp, in: snapshot.operations),
           case .undo(let targetID) = undoOp.payload {
            effectiveOperations.removeAll { $0.operationID == targetID }
            effectiveOperations.removeAll { $0.operationID == undoOp.operationID }
        }

        // 2. 限制与解除：恢复必须见过全部限制（限制优先，不静默解除未见过的限制）。
        let restrictions = effectiveOperations.filter { $0.kind.isUsageRestricting }
        var activeRestrictions = restrictions
        for lifting in effectiveOperations where lifting.kind == .restore {
            guard canLift(lifting, restrictions: restrictions) else { continue }
            // 恢复只解除停用类限制（disable/narrowScope）；不准确与遗忘不能被恢复单方解除。
            let liftableKinds: Set<HoloKnowledgeOperationKind> = [.disable, .narrowScope, .sourceInvalidation]
            activeRestrictions.removeAll { restriction in
                liftableKinds.contains(restriction.kind)
                    && lifting.priorOperationIDs.contains(restriction.operationID)
            }
        }

        let restrictionIDs = Set(activeRestrictions.map(\.operationID))

        // 3. 遗忘：正文清除，仅留最小无正文阻断（§7.6）。
        if activeRestrictions.contains(where: { $0.kind == .forget }) {
            return makeResolved(
                snapshot: snapshot,
                latest: nil,
                proposed: nil,
                confirmedDigest: nil,
                decision: .inactive,
                reasons: ["forgotten"],
                uses: [],
                restrictionIDs: restrictionIDs,
                formation: latest.semantic.formation,
                undoableOperationID: lastUserOperationID(in: effectiveOperations)
            )
        }

        // 3.5 不可读/冲突数据：同一命题存在解码失败行或同 ID 不同内容冲突行
        //     （09-R06/R07）——原字节保留在库，命题整体保守限制，不用碰运气取一条。
        if snapshot.hasUnreadableData {
            return makeResolved(
                snapshot: snapshot,
                latest: latest,
                proposed: nil,
                confirmedDigest: nil,
                decision: .inactive,
                reasons: ["unreadableOrConflicted"],
                uses: [],
                restrictionIDs: restrictionIDs,
                formation: latest.semantic.formation,
                undoableOperationID: lastUserOperationID(in: effectiveOperations)
            )
        }

        // 4. 有效确认：确认必须见过全部当前限制（放宽不解除未见限制），
        //    且确认绑定的语义指纹必须仍有对应修订。
        let effectiveConfirms = effectiveOperations.filter { $0.kind == .confirm }
        var confirmedDigest: String?
        for confirm in effectiveConfirms.reversed() {
            guard canLift(confirm, restrictions: activeRestrictions) else { continue }
            let digest = confirm.targetSemanticDigest
                ?? {
                    if case .confirmation(let semanticDigest, _) = confirm.payload { return semanticDigest }
                    return nil
                }()
            guard let digest,
                  snapshot.revisions.contains(where: { $0.semanticDigest == digest }) else { continue }
            confirmedDigest = digest
            break
        }

        // 5. 语义被否定：markInaccurate(understanding) 阻断其目标语义；不封禁整个主题。
        let inaccurateDigests = Set(
            effectiveOperations
                .filter { op in
                    if op.kind != .markInaccurate { return false }
                    if case .inaccurate(_, let scope) = op.payload, scope == .applicability { return false }
                    return true
                }
                .compactMap(\.targetSemanticDigest)
        )

        // 6. 当前权威修订与待确认修订。
        let confirmedRevision = confirmedDigest.flatMap { digest in
            snapshot.revisions.first { $0.semanticDigest == digest }
        }
        let proposed = latest.semanticRevisionID == confirmedRevision?.semanticRevisionID ? nil : latest

        // 7. 冷却（暂不处理不是否定）。
        let cooldownUntil = effectiveOperations
            .last { $0.kind == .deferCooldown }
            .flatMap { op -> Date? in
                if case .cooldown(let until) = op.payload { return until }
                return op.issuedAt.addingTimeInterval(30 * 86_400)
            }

        // 8. 基础投影
        let resolved = makeResolved(
            snapshot: snapshot,
            latest: latest,
            proposed: proposed,
            confirmedDigest: confirmedDigest,
            decision: .internalAccumulating,
            reasons: [],
            uses: [],
            restrictionIDs: restrictionIDs,
            formation: latest.semantic.formation,
            undoableOperationID: lastUserOperationID(in: effectiveOperations)
        )

        return decorate(
            resolved,
            snapshot: snapshot,
            latest: latest,
            confirmedRevision: confirmedRevision,
            proposed: proposed,
            confirmedDigest: confirmedDigest,
            inaccurateDigests: inaccurateDigests,
            activeRestrictions: activeRestrictions,
            cooldownUntil: cooldownUntil
        )
    }

    // MARK: 决策链

    private static func decorate(
        _ resolved: HoloResolvedKnowledge,
        snapshot: HoloKnowledgeResolutionSnapshot,
        latest: HoloKnowledgeRevision,
        confirmedRevision: HoloKnowledgeRevision?,
        proposed: HoloKnowledgeRevision?,
        confirmedDigest: String?,
        inaccurateDigests: Set<String>,
        activeRestrictions: [HoloKnowledgeOperation],
        cooldownUntil: Date?
    ) -> HoloResolvedKnowledge {
        var result = resolved
        var reasons: [String] = []
        let now = snapshot.now
        let current = confirmedRevision ?? latest

        func finish(_ decision: HoloKnowledgeDecisionState, _ uses: Set<HoloKnowledgeAllowedUse>, _ why: [String]) -> HoloResolvedKnowledge {
            result.decision = decision
            result.decisionReasons = why
            result.allowedUses = decision.isUsableForAnswering ? uses : []
            result.currentRevision = decision.isUsableForAnswering ? current : nil
            // 同一命题可同时有「仍有效的已确认版本」与「待确认的新建议版本」（§2.4）。
            result.proposedRevision = proposed ?? (decision == .worthConfirming ? current : nil)
            result.confirmedSemanticDigest = confirmedDigest
            result.cooldownUntil = cooldownUntil
            // 最新证据快照：证据刷新操作优先于修订初始快照（展示数字随快照更新）。
            result.latestEvidenceSnapshot = latestEvidence(in: snapshot, current: current)
            return result
        }

        let baseUses = Set(current.semantic.allowedUses)

        // 8a. 停用：保留可恢复历史，不当作当前确定知识。
        if activeRestrictions.contains(where: { $0.kind == .disable }) {
            return finish(.inactive, [], ["disabled"])
        }

        // 8a-2. 旧记录退役（迁移复评）：新分类口径下不再作为当前理解。
        // 不属于用户权威操作，展示层归入「过去的记忆」，AI 使用侧停用。
        if activeRestrictions.contains(where: { $0.kind == .legacyRetire }) {
            return finish(.inactive, [], ["legacyRetired"])
        }

        // 8b. 来源失效：sourceLinked / behavioralInference 停用；用户陈述独立来源不阻断。
        let formation = current.semantic.formation
        let sourceDependent = formation == .sourceLinked || formation == .behavioralInference
        if sourceDependent, snapshot.sourceStatus.isBlockingUsage {
            reasons.append("source:\(snapshot.sourceStatus.rawValue)")
            return finish(.inactive, [], reasons)
        }

        // 8c. 语义被否定（当前权威语义被 markInaccurate 命中）。
        if inaccurateDigests.contains(current.semanticDigest) {
            return finish(.inactive, [], ["inaccurate"])
        }

        // 8d. 学习基线：清空后旧证据不能自动变成全新生活证据（§7.5）。
        if let baseline = snapshot.learningBaselineAt,
           let snapshotRefs = latestEvidence(in: snapshot, current: current) {
            let refs = snapshotRefs.supportRefs
            if !refs.isEmpty, refs.allSatisfy({ $0.observedAt < baseline }) {
                return finish(.inactive, [], ["preLearningBaseline"])
            }
        }

        // 8e. 时效：只有「当前状态类」按适用范围判过期（偏好持续有效直至修改；
        //     已发生的阶段/事件是历史事实，不因时间流逝失真）。
        let capturedAt = latestEvidence(in: snapshot, current: current)?.capturedAt ?? current.createdAt
        if isCurrentStateSemantic(current.semantic, capturedAt: capturedAt), isExpired(current.semantic, now: now) {
            return finish(.inactive, [], ["expired"])
        }

        // 8f. 收窄：narrowScope 的 validTo 已过 → 历史（不假定以前从未发生）。
        if let narrowing = activeRestrictions.last(where: { $0.kind == .narrowScope }),
           case .narrowing(let validTo) = narrowing.payload, validTo < now {
            return finish(.inactive, [], ["narrowedExpired"])
        }

        // 8g. 冲突：存在反例且未被后续证据吸收 → 次级历史，需要时澄清。
        if let snapshotRefs = latestEvidence(in: snapshot, current: current),
           !snapshotRefs.counterRefs.isEmpty,
           snapshotRefs.counterexampleSearch == .searchedFound {
            return finish(.inactive, [], ["conflict"])
        }

        // 8h. 已确认且仍有效。
        if let confirmedRevision {
            var uses = baseUses
            if confirmedRevision.semantic.formation == .behavioralInference,
               confirmedRevision.initialEvidenceSnapshot.templateID != HoloKnowledgeTemplateID.boundedRecurrence.rawValue {
                uses.formUnion([.backgroundUnderstanding, .qualifiedAdvice])
            }
            return finish(.confirmedValid, uses, ["confirmed"])
        }

        // 8i. 直接陈述 / 来源关联 / 用户纠正：已记住（按 §4 第三行）。
        switch formation {
        case .directExpression, .userCorrection:
            return finish(.remembered, baseUses, [HoloKnowledgeAdmissionReason.directStatementAccepted.rawValue])
        case .sourceLinked:
            if snapshot.sourceStatus == .verified || snapshot.sourceStatus == .revised {
                return finish(.remembered, baseUses, [HoloKnowledgeAdmissionReason.sourceLinkedAccepted.rawValue])
            }
            return finish(.inactive, [], ["source:\(snapshot.sourceStatus.rawValue)"])
        case .behavioralInference:
            // 8j. 行为归纳：证据与模板成熟度决定「值得确认」，确认前不跨会话使用。
            let admission = HoloKnowledgeAdmission.assess(
                semantic: current.semantic,
                evidence: latestEvidence(in: snapshot, current: current) ?? current.initialEvidenceSnapshot,
                authorizedSourceDomains: Set(current.domains)
            )
            switch admission {
            case .worthConfirming:
                return finish(.worthConfirming, [.sourceLinkForPreciseQuery], [HoloKnowledgeAdmissionReason.matureInference.rawValue])
            case .remembered:
                // 行为归纳不因证据充分自动变已记住：必须经过用户确认（§0）。
                return finish(.worthConfirming, [.sourceLinkForPreciseQuery], [HoloKnowledgeAdmissionReason.matureInference.rawValue])
            case .internalOnly(let reason):
                return finish(.internalAccumulating, [], [reason.rawValue])
            case .reject(let reason):
                return finish(.noValue, [], [reason.rawValue])
            }
        }
    }

    // MARK: 辅助

    private static func latestEvidence(
        in snapshot: HoloKnowledgeResolutionSnapshot,
        current: HoloKnowledgeRevision
    ) -> HoloKnowledgeEvidenceSnapshot? {
        // 最新 evidenceSnapshot 操作优先于修订的初始快照（普通证据刷新不改语义版本）。
        // 刷新必须绑定目标修订（09-R04）：v1 已确认版与 v2 待确认版交错刷新时，
        // 各取各的快照；命题级（target 为空）刷新视为适用全部修订。
        let refresh = snapshot.operations
            .last { operation in
                guard operation.kind == .evidenceSnapshot else { return false }
                let targetRevisionID = operation.targetSemanticRevisionID
                let targetDigest = operation.targetSemanticDigest
                if targetRevisionID == nil && targetDigest == nil { return true }
                return targetRevisionID == current.semanticRevisionID
                    || targetDigest == current.semanticDigest
            }
            .flatMap { operation -> HoloKnowledgeEvidenceSnapshot? in
                if case .evidenceSnapshot(let refreshed) = operation.payload { return refreshed }
                return nil
            }
        return refresh ?? current.initialEvidenceSnapshot
    }

    private static func isLatestUserOperation(
        _ operation: HoloKnowledgeOperation,
        in all: [HoloKnowledgeOperation]
    ) -> Bool {
        guard let lastUser = all.last(where: { $0.kind.isUserAuthority }) else { return false }
        return lastUser.operationID == operation.operationID
    }

    private static func lastUserOperationID(in operations: [HoloKnowledgeOperation]) -> String? {
        operations.last(where: { $0.kind.isUserAuthority })?.operationID
    }

    /// 恢复/确认有效性：必须见过全部当前限制（§2.4 跨设备并发控制代数）。
    private static func canLift(
        _ lifting: HoloKnowledgeOperation,
        restrictions: [HoloKnowledgeOperation]
    ) -> Bool {
        restrictions.allSatisfy { lifting.priorOperationIDs.contains($0.operationID) }
    }

    private static func makeResolved(
        snapshot: HoloKnowledgeResolutionSnapshot,
        latest: HoloKnowledgeRevision?,
        proposed: HoloKnowledgeRevision?,
        confirmedDigest: String?,
        decision: HoloKnowledgeDecisionState,
        reasons: [String],
        uses: Set<HoloKnowledgeAllowedUse>,
        restrictionIDs: Set<String>,
        formation: HoloKnowledgeFormation,
        undoableOperationID: String?
    ) -> HoloResolvedKnowledge {
        let anchor = latest
        return HoloResolvedKnowledge(
            propositionID: snapshot.propositionID,
            topicID: anchor?.topicID ?? "",
            topicLabel: anchor?.topicLabel ?? "",
            domains: anchor?.domains ?? [],
            partition: anchor?.partition ?? .normal,
            sensitivity: anchor?.sensitivity ?? .normal,
            currentRevision: nil,
            proposedRevision: nil,
            confirmedSemanticDigest: confirmedDigest,
            latestEvidenceSnapshot: anchor?.initialEvidenceSnapshot,
            decision: decision,
            decisionReasons: reasons,
            sourceStatus: snapshot.sourceStatus,
            allowedUses: uses,
            controlGeneration: snapshot.controlGeneration,
            restrictingOperationIDs: restrictionIDs,
            cooldownUntil: nil,
            formation: formation,
            lastUpdatedAt: anchor.map { max($0.createdAt, snapshot.operations.last?.issuedAt ?? $0.createdAt) } ?? snapshot.now,
            legacyAliases: anchor?.sourceAliases ?? [],
            isLegacyRestricted: false,
            undoableOperationID: undoableOperationID
        )
    }

    /// 当前状态类命题：描述「现在如何」，过期即失真。结构判据——绝对窗口的终点在
    /// 证据捕获时仍在未来（「未来两周不宜跑步」）= 当前限制/状态；终点已在过去
    ///（「去年那次旅行」「0–28 日的阅读节奏」）= 历史事实/阶段结论，不因时间流逝失效。
    /// 偏好（ongoing）与周期规则表达「持续有效/曾出现」，不适用。
    static func isCurrentStateSemantic(_ semantic: HoloKnowledgeSemantic, capturedAt: Date) -> Bool {
        guard semantic.evidenceForm != .intervalRuleWithExceptions else { return false }
        switch semantic.applicability.windowRule {
        case .ongoing, .recurrence:
            return false
        case .rolling:
            return true
        case .absolute(_, let to):
            guard let to else { return false }
            return to > capturedAt
        }
    }

    private static func isExpired(_ semantic: HoloKnowledgeSemantic, now: Date) -> Bool {
        switch semantic.applicability.windowRule {
        case .ongoing:
            return false
        case .absolute(_, let to):
            return to.map { $0 < now } ?? false
        case .rolling(let days):
            // 滚动窗按确认的规则更新；无锚点信息时不误判过期。
            return days > 0 ? false : true
        case .recurrence:
            return false
        }
    }
}
