//
//  HoloKnowledgeIngestion.swift
//  Holo
//
//  统一写入（方案 v2.2 §6 全链路接入 / §7.2 存量分流）
//
//  所有产生者（信号适配器、观察器、个人情境萃取、生活源观察、报告派生）仍产出
//  HoloMemoryRecord 作为「来源/候选契约」载体，进入仓库写路径后在同一事务内
//  经统一准入落知识修订；不直接用候选状态授权当前理解。
//  同一映射被迁移引擎复用：旧记录按 §7.2 分类后走同一准入与身份。
//

import CoreData
import Foundation

// MARK: - 候选 → 共同观察契约

nonisolated enum HoloKnowledgeIngestion {
    static let producerVersion = 1
    static let producerName = "legacyRecordBridge"

    /// 把一条记忆记录解释为共同观察契约。返回 nil = 结构无法表达（不猜）。
    static func assessment(
        from record: HoloMemoryRecord,
        purpose: HoloObservationAssessment.Purpose = .memory,
        persistenceAuthorized: Bool,
        now: Date
    ) -> HoloObservationAssessment? {
        guard let semantic = semantic(from: record) else { return nil }
        let evidence = evidenceSnapshot(from: record, now: now)
        return HoloObservationAssessment(
            purpose: purpose,
            semantic: semantic,
            evidenceSnapshot: evidence,
            domains: Array(Set(record.sourceDomains + (record.primaryDomain.map { [$0] } ?? []))).sorted(),
            sensitivity: record.sensitivity,
            authorizedSourceDomains: Set(HoloMemoryDomain.allCases),
            persistenceAuthorized: persistenceAuthorized,
            origin: HoloKnowledgeOrigin(kind: .producer, legacyRecordID: record.id, producer: producerName)
        )
    }

    // MARK: 语义映射（领域只负责解释原始数据，不按实体词编分支）

    static func semantic(from record: HoloMemoryRecord) -> HoloKnowledgeSemantic? {
        let payload = record.personalContext?.v1
        let formation = formation(for: record, payload: payload)
        let evidenceForm = evidenceForm(for: record, payload: payload)

        // 主体：个人情境主体含非本人（person/group）即第三方命题；否则 self。
        let subjectRef: String
        if let payload,
           let party = payload.subjects.first(where: { $0.scope == .person || $0.scope == .group }) {
            subjectRef = party.ref ?? HoloKnowledgeIdentity.freeSemanticSlot(party.label)
        } else {
            subjectRef = "self"
        }

        // 对象：业务 ID 优先，其次持久化自由语义槽位（名字/商家名不能充当唯一身份）。
        let objectRef: String?
        if let payload, let object = payload.objects.first {
            objectRef = object.ref ?? HoloKnowledgeIdentity.freeSemanticSlot(object.label)
        } else if let anchor = HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).first {
            objectRef = anchor.stableKey
        } else {
            return nil
        }

        let relation: String
        let dimension: String
        if let payload {
            let normalizedRelation = HoloKnowledgeIdentity.normalize(payload.relationText)
            relation = normalizedRelation.isEmpty ? "context" : normalizedRelation
            dimension = payload.facets.first.map { "facet:\($0.kind.rawValue)" } ?? "claim:\(record.claimKind.rawValue)"
        } else {
            relation = "claim:\(record.claimKind.rawValue)"
            dimension = "claim:\(record.claimKind.rawValue)"
        }

        var qualifiers = record.prohibitedInferences
        if payload?.epistemicStatus == .inferred { qualifiers.append("模型推断") }
        if record.claimKind == .hypothesis { qualifiers.append("用户的个人解释") }
        if record.claimKind == .association || record.claimKind == .tension { qualifiers.append("相关非因果") }

        let display = record.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let aiUse = record.aiUseSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }

        return HoloKnowledgeSemantic(
            subjectRef: subjectRef,
            objectRef: objectRef,
            relation: relation,
            polarity: true,
            objectValue: nil,
            dimension: dimension,
            qualifiers: Array(Set(qualifiers)).sorted(),
            applicability: applicability(for: record, payload: payload),
            allowedUses: allowedUses(for: record),
            formation: formation,
            evidenceForm: evidenceForm,
            displayText: display,
            aiUseText: aiUse.isEmpty ? display : aiUse,
            prohibitedInferences: record.prohibitedInferences
        )
    }

    static func evidenceSnapshot(from record: HoloMemoryRecord, now: Date) -> HoloKnowledgeEvidenceSnapshot {
        let support = record.evidenceRefs
        // 独立事件数 = 去重后的底层血缘（09-R12）：总天数/样本数不能充当实际发生次数。
        let independent = Set(support.map(\.lineageKey)).count
        let windowFrom = support.compactMap { $0.validFrom ?? $0.observedAt }.min()
        let windowTo = support.compactMap { $0.validTo ?? $0.observedAt }.max()
        let samples = support.compactMap(\.sampleCount).reduce(0, +)
        let templateID = HoloKnowledgeTemplateRegistry.templateID(for: record.claimKind, scope: record.scope)
        var revisions: [String: String] = [:]
        for ref in support + record.counterEvidenceRefs {
            revisions[ref.lineageKey] = ref.revisionDigest
        }
        return HoloKnowledgeEvidenceSnapshot(
            supportRefs: support,
            counterRefs: record.counterEvidenceRefs,
            observationWindowFrom: windowFrom,
            observationWindowTo: windowTo,
            independentEventCount: independent,
            coveragePercent: nil,
            // 没有真实反例检索就如实 notSearched（09-R12）：跨域桥接没有查过
            // 不能标 searchedNoneFound——「未查明」不冒充「查过没有」。
            counterexampleSearch: record.counterEvidenceRefs.isEmpty
                ? .notSearched
                : .searchedFound,
            templateID: templateID?.rawValue,
            // 完整周期 = 有记录的去重 ISO 自然周数（真实可推导：每个计数的周
            // 都有至少一条记录；机会分母口径由后续统计服务接入，不在此伪造）。
            completePeriods: Self.completeCalendarWeeks(of: support),
            statsSummary: samples > 0 ? "样本 \(samples)" : nil,
            sourceRevisions: revisions,
            holdoutValidatedPeriods: nil,
            capturedAt: record.updatedAt > Date(timeIntervalSince1970: 0) ? record.updatedAt : now
        )
    }

    /// 去重 ISO 自然周计数：(yearForWeekOfYear, weekOfYear) 组合键。
    static func completeCalendarWeeks(of refs: [HoloMemoryEvidenceRef]) -> Int? {
        let dates = refs.compactMap(\.observedAt)
        guard !dates.isEmpty else { return nil }
        let calendar = Calendar(identifier: .iso8601)
        let weeks = Set(dates.map { date in
            "\(calendar.component(.yearForWeekOfYear, from: date))-W\(calendar.component(.weekOfYear, from: date))"
        })
        return weeks.count
    }

    /// 周覆盖率的确定性近似（发现桥与财务规律挖矿共用的唯一口径）：
    /// 有观察的自然周数 / 观察跨度覆盖的周数（「每周被比较分组均有有效可比观察」
    /// 的可测试定义；跨设备用固定 gregorian，firstWeekday=周一）。
    static func weeklyCoverage(of dates: [Date]) -> Double? {
        guard let first = dates.min(), let last = dates.max(), last > first else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let weeks = Set(dates.map {
            calendar.component(.weekOfYear, from: $0) * 100 + calendar.component(.yearForWeekOfYear, from: $0)
        })
        let spanWeeks = max(1, Int(ceil(last.timeIntervalSince(first) / (7 * 86_400))))
        return min(1, Double(weeks.count) / Double(spanWeeks))
    }

    // MARK: 形成方式 / 证据形态 / 适用范围 / 用途

    /// 用户原话的可达域：对话消息与用户亲写的想法；账单/任务/打卡/目标是
    /// 业务记录（09-R01 写入端口径）。读取端用同一口径纠正历史错标——
    /// 修复前的存量把业务来源证据整体标成 explicitUserStatement，导致
    /// 单笔流水被当成「你告诉 Holo 的」展示并受保护（2026-11-01 修复批）。
    static func isUserWordsDomain(_ sourceKey: String) -> Bool {
        ["conversation", "thought"].contains(HoloLifeSourceKeys.domain(of: sourceKey))
    }

    static func formation(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloKnowledgeFormation {
        if record.userDecision == .corrected { return .userCorrection }
        if let payload {
            switch payload.epistemicStatus {
            case .declared:
                // 「用户明说」必须出自用户原话域：业务记录（账单/打卡/任务）上的
                // declared 是模型把记录内容当陈述——按结构规则降级判读。
                if payload.basis.contains(where: { isUserWordsDomain($0.sourceID) }) {
                    return .directExpression
                }
            case .observed: return .sourceLinked
            case .inferred: return .behavioralInference
            }
        }
        if record.evidenceRefs.contains(where: {
            $0.kind == .explicitUserStatement && $0.sourceDomain == .conversation
        }) {
            return .directExpression
        }
        if record.claimKind == .explicitPreference,
           record.evidenceRefs.contains(where: { isUserWordsDomain($0.lineageKey) }) {
            return .directExpression
        }
        if record.scope == .crossDomain { return .behavioralInference }
        switch record.claimKind {
        case .recurringPattern, .phaseShift, .association, .tension, .hypothesis:
            return .behavioralInference
        case .observedFact, .lifeEvent, .explicitPreference:
            return .sourceLinked
        }
    }

    static func evidenceForm(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloKnowledgeEvidenceForm {
        if record.evidenceRefs.contains(where: {
            $0.kind == .explicitUserStatement && $0.sourceDomain == .conversation
        }) || (payload?.epistemicStatus == .declared && payload!.basis.contains(where: { isUserWordsDomain($0.sourceID) })) {
            return .explicitSemanticFact
        }
        if record.scope == .crossDomain { return .multiSourceSemanticRelation }
        if payload?.temporal?.kind == .recurring { return .intervalRuleWithExceptions }
        if record.evidenceRefs.contains(where: { $0.kind == .aggregateSnapshot }) {
            return .sampledNumericSeries
        }
        switch record.claimKind {
        // 行为规律来自独立事件集合（打卡/完成/消费）；周期规则形态只由明确的 recurring 时间语义给出。
        case .recurringPattern: return .independentEventSet
        case .association, .tension: return .multiSourceSemanticRelation
        case .phaseShift: return .sampledNumericSeries
        case .observedFact, .lifeEvent, .hypothesis, .explicitPreference: return .independentEventSet
        }
    }

    static func applicability(
        for record: HoloMemoryRecord,
        payload: HoloPersonalContextPayloadV1?
    ) -> HoloKnowledgeApplicability {
        let condition = payload?.applicability.conditionText
        let exceptions = payload?.temporal?.exceptions ?? []
        if let temporal = payload?.temporal {
            switch temporal.kind {
            case .event:
                return HoloKnowledgeApplicability(
                    windowRule: .absolute(from: temporal.validFrom ?? record.validFrom, to: temporal.validTo ?? record.validTo),
                    conditionText: condition,
                    exceptions: exceptions
                )
            case .ongoing:
                return HoloKnowledgeApplicability(windowRule: .ongoing, conditionText: condition, exceptions: exceptions)
            case .recurring:
                let rule = temporal.recurrence.map {
                    "\($0.frequency.rawValue)/\($0.interval)" + ($0.weekday.map { "/wd\($0)" } ?? "") + ($0.dayOfMonth.map { "/dom\($0)" } ?? "")
                } ?? "recurring"
                return HoloKnowledgeApplicability(windowRule: .recurrence(rule: rule), conditionText: condition, exceptions: exceptions)
            case .conditional:
                return HoloKnowledgeApplicability(
                    windowRule: .ongoing,
                    conditionText: condition ?? temporal.triggerText,
                    exceptions: exceptions
                )
            }
        }
        switch record.claimKind {
        case .explicitPreference:
            return HoloKnowledgeApplicability(windowRule: .ongoing, conditionText: condition)
        case .lifeEvent, .phaseShift, .observedFact:
            if record.validFrom != nil || record.validTo != nil {
                return HoloKnowledgeApplicability(
                    windowRule: .absolute(from: record.validFrom, to: record.validTo),
                    conditionText: condition
                )
            }
            return HoloKnowledgeApplicability(windowRule: .ongoing, conditionText: condition)
        case .recurringPattern:
            return HoloKnowledgeApplicability(windowRule: .recurrence(rule: "observed"), conditionText: condition)
        case .association, .tension, .hypothesis:
            if let from = record.validFrom, let to = record.validTo {
                return HoloKnowledgeApplicability(windowRule: .absolute(from: from, to: to), conditionText: condition)
            }
            return HoloKnowledgeApplicability(windowRule: .ongoing, conditionText: condition)
        }
    }

    static func allowedUses(for record: HoloMemoryRecord) -> Set<HoloKnowledgeAllowedUse> {
        guard let useLevel = record.decisionMetadata?.v2?.useLevel else {
            return [.backgroundUnderstanding, .sourceLinkForPreciseQuery]
        }
        switch useLevel {
        case .factEligible: return [.backgroundUnderstanding, .qualifiedAdvice, .sourceLinkForPreciseQuery]
        case .qualifiedAdvice: return [.backgroundUnderstanding, .qualifiedAdvice, .sourceLinkForPreciseQuery]
        case .observeOnly: return [.sourceLinkForPreciseQuery]
        case .blocked, .unrecognized: return []
        }
    }

    // MARK: 同事务落知识（仓库写路径调用）

    nonisolated enum Outcome: Equatable, Sendable {
        case notExpressible
        case rejected(HoloKnowledgeAdmissionReason)
        case internalOnly(HoloKnowledgeAdmissionReason)
        /// 新修订已写入
        case revisionInserted(propositionID: String, semanticRevisionID: String)
        /// 同语义已存在：只刷新证据快照（不增新记忆、不反复确认）
        case evidenceRefreshed(propositionID: String)
        /// 同语义同证据：无变化
        case unchanged(propositionID: String)
    }

    /// 在旧记录写入的同一 NSManagedObjectContext 内落知识修订/证据快照。
    /// 只在准入通过（remembered / worthConfirming）时写知识；内部积累与拒绝停留在旧候选存储。
    /// 幂等：修订 ID 与证据快照操作 ID 都由内容确定，重复写入无副作用。
    @discardableResult
    static func ingest(
        record: HoloMemoryRecord,
        controlGeneration: Int64,
        now: Date,
        in context: NSManagedObjectContext
    ) throws -> Outcome {
        // 被拒绝/遗忘/终态记录不产生新知识：阻断范围由迁移引擎显式导入为限制操作，
        // 写路径不得把旧否定内容再当候选（§3.3 用户直接纠正优先于自动批次）。
        if [.rejected, .forgotten].contains(record.userDecision)
            || [HoloMemoryState.suppressed, .tombstoned, .deleted, .invalidated].contains(record.state) {
            return .rejected(.unsupportedClaim)
        }
        guard let assessment = assessment(from: record, persistenceAuthorized: true, now: now) else {
            return .notExpressible
        }
        let verdict = HoloKnowledgeAdmission.assess(
            semantic: assessment.semantic,
            evidence: assessment.evidenceSnapshot,
            authorizedSourceDomains: assessment.authorizedSourceDomains
        )
        switch verdict {
        case .reject(let reason): return .rejected(reason)
        case .internalOnly(let reason): return .internalOnly(reason)
        case .remembered, .worthConfirming: break
        }

        let partition = assessment.partition
        let propositionID = assessment.propositionID
        let existingRevisions = try fetchRevisions(propositionID: propositionID, in: context)
        let predecessor = existingRevisions
            .filter { $0.semanticDigest != assessment.semanticDigest }
            .max { $0.createdAt < $1.createdAt }

        let revision = HoloKnowledgeRevision.make(
            semantic: assessment.semantic,
            topicLabel: topicLabel(for: record),
            domains: assessment.domains,
            sensitivity: assessment.sensitivity,
            partition: partition,
            evidenceSnapshot: assessment.evidenceSnapshot,
            sourceAliases: [record.id],
            origin: assessment.origin,
            predecessorRevisionID: predecessor?.semanticRevisionID,
            createdAt: now
        )

        let inserted = try CoreDataHoloMemoryRepository.upsertKnowledgeRevision(revision, in: context)
        if inserted {
            return .revisionInserted(propositionID: revision.propositionID, semanticRevisionID: revision.semanticRevisionID)
        }

        // 同语义已存在：仅在证据快照变化时追加 evidenceSnapshot 操作（不增新记忆、不反复确认）。
        let snapshotID = assessment.evidenceSnapshot.id
        let lastSnapshotID = try lastEvidenceSnapshotID(propositionID: propositionID, in: context)
            ?? existingRevisions.first { $0.semanticDigest == assessment.semanticDigest }?.initialEvidenceSnapshot.id
        guard snapshotID != lastSnapshotID else {
            return .unchanged(propositionID: revision.propositionID)
        }
        let operation = HoloKnowledgeOperation(
            operationID: "es-\(revision.semanticRevisionID)-\(snapshotID)",
            kind: .evidenceSnapshot,
            propositionID: revision.propositionID,
            targetSemanticRevisionID: revision.semanticRevisionID,
            targetSemanticDigest: revision.semanticDigest,
            controlGeneration: controlGeneration,
            payload: .evidenceSnapshot(assessment.evidenceSnapshot),
            partition: partition,
            issuedAt: now
        )
        _ = try CoreDataHoloMemoryRepository.upsertKnowledgeOperation(operation, in: context)
        return .evidenceRefreshed(propositionID: revision.propositionID)
    }

    private static func fetchRevisions(
        propositionID: String,
        in context: NSManagedObjectContext
    ) throws -> [HoloKnowledgeRevision] {
        let request = NSFetchRequest<HoloMemoryKnowledgeRevisionMO>(entityName: "HoloMemoryKnowledgeRevisionMO")
        request.predicate = NSPredicate(format: "propositionID == %@ AND deletedAt == nil", propositionID)
        return try context.fetch(request).compactMap {
            try? CoreDataHoloMemoryRepository.knowledgeDecoder().decode(HoloKnowledgeRevision.self, from: $0.revisionData)
        }
    }

    private static func lastEvidenceSnapshotID(
        propositionID: String,
        in context: NSManagedObjectContext
    ) throws -> String? {
        let request = NSFetchRequest<HoloMemoryKnowledgeOperationMO>(entityName: "HoloMemoryKnowledgeOperationMO")
        request.predicate = NSPredicate(
            format: "propositionID == %@ AND kind == %@",
            propositionID, HoloKnowledgeOperationKind.evidenceSnapshot.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "issuedAt", ascending: false)]
        request.fetchLimit = 1
        guard let object = try context.fetch(request).first,
              let operation = try? CoreDataHoloMemoryRepository.knowledgeDecoder().decode(HoloKnowledgeOperation.self, from: object.operationData),
              case .evidenceSnapshot(let snapshot) = operation.payload else {
            return nil
        }
        return snapshot.id
    }

    static func topicLabel(for record: HoloMemoryRecord) -> String {
        if let anchor = HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).first {
            return anchor.displayLabel ?? anchor.canonicalValue
        }
        return record.subjectKey
    }
}

// MARK: - §7.2 存量分流（旧记录只读分类；迁移与未迁移受限投影共用）

nonisolated enum HoloKnowledgeLegacyClassification: String, Equatable, Sendable, CaseIterable {
    /// 可靠用户陈述、用户添加或纠正：保留精确原意、范围与用户权威
    case reliableUserStatement
    /// 已确认的行为规律：原确认仅适用原命题
    case confirmedPattern
    /// 已确认的单次事件：保留确认，不扩成持续属性，不占主确认队列
    case confirmedSingleEvent
    /// 自动生成的单次流水/低价值：退出主记忆与持续召回
    case autoLowValue
    /// 自动规律/关联但未确认：有原始支持才进聚合，不因旧 active 自动当已认可
    case autoInferenceUnconfirmed
    /// 不准确/停用/遗忘/墓碑：原因与阻断范围先导入
    case blocked
    /// 未知版本/无可核对来源/歧义身份：单条保留原数据、排除新能力
    case unresolvable

    /// 未迁移时的受限只读投影是否可用于回答（§7.3：不通过旧 active 查询悄悄回退）。
    var isUsableWithoutMigration: Bool {
        switch self {
        case .reliableUserStatement, .confirmedPattern, .confirmedSingleEvent: return true
        case .autoLowValue, .autoInferenceUnconfirmed, .blocked, .unresolvable: return false
        }
    }
}

nonisolated enum HoloKnowledgeLegacyAdapter {
    static func classify(_ record: HoloMemoryRecord) -> HoloKnowledgeLegacyClassification {
        if [.rejected, .forgotten].contains(record.userDecision)
            || [HoloMemoryState.suppressed, .tombstoned, .deleted].contains(record.state) {
            return .blocked
        }
        if record.evidenceRefs.isEmpty, ![HoloMemoryState.tombstoned, .deleted, .suppressed].contains(record.state) {
            return .unresolvable
        }
        if let envelope = record.decisionMetadata, !envelope.isReadable {
            return .unresolvable
        }
        let payload = record.personalContext?.v1
        if let personal = record.personalContext, !personal.isReadable {
            return .unresolvable
        }
        let formation = HoloKnowledgeIngestion.formation(for: record, payload: payload)
        switch record.userDecision {
        case .corrected:
            return .reliableUserStatement
        case .confirmed:
            if formation == .directExpression { return .reliableUserStatement }
            if record.claimKind == .lifeEvent || payload?.temporal?.kind == .event { return .confirmedSingleEvent }
            return .confirmedPattern
        case .none, .markedIrrelevant:
            break
        case .rejected, .forgotten:
            return .blocked
        }
        if formation == .directExpression || formation == .userCorrection {
            return .reliableUserStatement
        }
        if formation == .behavioralInference {
            return .autoInferenceUnconfirmed
        }
        // sourceLinked：单条流水退出，有界/有情境的保留为自动（迁移时按准入再判）
        if record.evidenceRefs.count < 2, record.claimKind == .observedFact, record.validFrom == nil {
            return .autoLowValue
        }
        return .autoInferenceUnconfirmed
    }

    static func isUsableWithoutMigration(_ record: HoloMemoryRecord) -> Bool {
        record.state == .active && classify(record).isUsableWithoutMigration
    }
}
