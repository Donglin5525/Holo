//
//  DiscoveryKnowledgeLinkage.swift
//  Holo
//
//  「一个发现」与 Holo 记忆的融合联动（融合契约 §2–§6 / 主方案 §6.1）
//
//  共用来源规范化、命题/语义/证据身份：每个 finding 的具体 claim 关联到准确命题及
//  语义版本（findingID+runID+candidateID+claimID → propositionID+semanticDigest+
//  evidenceSnapshotID）。映射由程序建立，不让模型发明记忆 ID。
//  没有持久化授权时只保留发现目的下的临时关联键（DiscoveryStore，本机）；
//  用户「确认并记住」才进入统一知识修订与确认操作。
//

import CoreData
import Foundation

// MARK: - 关联键

struct DiscoveryClaimLinkage: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(findingID.uuidString)|\(claimID)" }

    let findingID: UUID
    let runID: String
    let candidateID: String
    let claimID: String
    let propositionID: String
    let semanticDigest: String
    let evidenceSnapshotID: String
    /// claim 对应的语义正文（保存时据此建修订；不依赖发现卡片存活）
    let semantic: HoloKnowledgeSemantic
    let evidenceSnapshot: HoloKnowledgeEvidenceSnapshot
    let domains: [HoloMemoryDomain]
    let createdAt: Date
}

// MARK: - 保存状态（详情页内联区域）

enum DiscoveryKnowledgeSaveState: Equatable, Sendable {
    /// 未达记忆门槛：维持「有点像／不太准确」，不显示不能兑现的保存按钮
    case notEligible
    /// 成熟且允许保存：显示准确待保存理解与「确认并记住」
    case eligible(claimID: String, preview: String, usesDescription: String)
    /// 已记住（两处显示同一状态）；辅助回答关闭时注明
    case remembered(propositionID: String, answeringEnabled: Bool)
    /// 来源已失效/语义已变化：不可保存
    case unavailable(reason: String)
}

enum DiscoveryKnowledgeSaveOutcome: Equatable, Sendable {
    case saved(propositionID: String)
    case alreadySaved(propositionID: String)
    /// 语义改变或出现未见限制：返回明确冲突，保留草稿
    case conflict(reason: String)
    case notEligible
    case failed(description: String)

    var isSuccess: Bool {
        switch self {
        case .saved, .alreadySaved: return true
        case .conflict, .notEligible, .failed: return false
        }
    }
}

// MARK: - 共同观察桥（程序推导语义与证据，不改模型 schema）

nonisolated enum DiscoveryKnowledgeBridge {
    static let originEntry = "discovery"

    static func memoryDomain(for kind: DiscoverySourceKind) -> HoloMemoryDomain? {
        switch kind {
        case .thought: return .thought
        case .task: return .task
        case .habitEvent: return .habit
        case .computedFact: return nil
        }
    }

    static func evidenceForm(for type: DiscoveryCandidateType) -> HoloKnowledgeEvidenceForm {
        switch type {
        case .twoEpisodes: return .independentEventSet
        case .boundedPattern: return .independentEventSet
        case .changeOverTime: return .sampledNumericSeries
        }
    }

    static func templateID(for type: DiscoveryCandidateType) -> HoloKnowledgeTemplateID? {
        switch type {
        case .twoEpisodes: return nil // 两次经历不是规律模板：永不自动升级
        case .boundedPattern: return .weeklyRhythm
        case .changeOverTime: return .comparableWindowChange
        }
    }

    /// claim 的准确语义：主体 self，对象为候选 subjectKey 的持久化槽位，维度为 claim 正文槽位。
    /// 措辞不同的 claim 保留区别（无法确定同一身份时不误合并）。
    static func semantic(
        for claim: DiscoveryClaim,
        candidate: DiscoveryCandidate
    ) -> HoloKnowledgeSemantic {
        let start = candidate.timeRange.start.flatMap(DiscoveryISO8601.parse)
        let end = candidate.timeRange.end.flatMap(DiscoveryISO8601.parse)
        let window: HoloKnowledgeApplicability.WindowRule = (start == nil && end == nil)
            ? .ongoing
            : .absolute(from: start, to: end)
        return HoloKnowledgeSemantic(
            subjectRef: "self",
            objectRef: HoloKnowledgeIdentity.freeSemanticSlot(candidate.subjectKey),
            relation: "discovery:\(candidate.type.rawValue)",
            polarity: true,
            objectValue: nil,
            dimension: "claim:\(HoloKnowledgeIdentity.fnv1a64(HoloKnowledgeIdentity.normalize(claim.text)))",
            qualifiers: ["发现观察", claim.kind == .observation ? "观察非事实" : "有限事实"],
            applicability: HoloKnowledgeApplicability(windowRule: window),
            allowedUses: [.backgroundUnderstanding, .sourceLinkForPreciseQuery],
            formation: .behavioralInference,
            evidenceForm: evidenceForm(for: candidate.type),
            displayText: claim.text,
            aiUseText: claim.text,
            prohibitedInferences: ["不要推断因果", "不要扩大到未观察的时间范围"]
        )
    }

    /// claim 的证据快照：引用 → 事实原子 → 真实业务来源；同一事件（血缘组）只计一次。
    static func evidenceSnapshot(
        for claim: DiscoveryClaim,
        candidate: DiscoveryCandidate,
        atoms: [String: DiscoveryFactAtom],
        counterAtoms: [DiscoveryFactAtom],
        counterCoverageComplete: Bool,
        now: Date
    ) -> HoloKnowledgeEvidenceSnapshot {
        var support: [HoloMemoryEvidenceRef] = []
        var lineageGroups = Set<String>()
        var revisions: [String: String] = [:]
        for citation in claim.citations {
            guard let atom = atoms[citation.evidenceID],
                  let ref = atom.localSourceRef,
                  let domain = memoryDomain(for: atom.sourceKind) else { continue }
            let lineage = ref.canonical
            revisions[lineage] = atom.sourceRevision
            switch atom.lineageGroup {
            case .group(let group): lineageGroups.insert(group)
            case .ambiguous: lineageGroups.insert(lineage)
            }
            support.append(HoloMemoryEvidenceRef(
                id: "disc-\(atom.evidenceID)-\(HoloKnowledgeIdentity.fnv1a64(lineage))",
                kind: .entityRef,
                sourceDomain: domain,
                lineageKey: lineage,
                sourceID: ref.localID,
                revisionDigest: atom.sourceRevision,
                observedAt: atom.occurredRange.start ?? atom.recordedAt,
                validFrom: atom.occurredRange.start,
                validTo: atom.occurredRange.end,
                summary: nil
            ))
        }
        var counter: [HoloMemoryEvidenceRef] = []
        for atom in counterAtoms {
            guard let ref = atom.localSourceRef,
                  let domain = memoryDomain(for: atom.sourceKind) else { continue }
            counter.append(HoloMemoryEvidenceRef(
                id: "disc-counter-\(atom.evidenceID)-\(HoloKnowledgeIdentity.fnv1a64(ref.canonical))",
                kind: .entityRef,
                sourceDomain: domain,
                lineageKey: ref.canonical,
                sourceID: ref.localID,
                revisionDigest: atom.sourceRevision,
                observedAt: atom.occurredRange.start ?? atom.recordedAt
            ))
            revisions[ref.canonical] = atom.sourceRevision
        }
        let dates = support.compactMap { $0.validFrom ?? $0.observedAt }
        let search: HoloKnowledgeCounterexampleSearchStatus
        if !counter.isEmpty {
            search = .searchedFound
        } else {
            search = counterCoverageComplete ? .searchedNoneFound : .notSearched
        }
        return HoloKnowledgeEvidenceSnapshot(
            supportRefs: support,
            counterRefs: counter,
            observationWindowFrom: dates.min(),
            observationWindowTo: dates.max(),
            independentEventCount: lineageGroups.count,
            coveragePercent: weeklyCoverage(of: dates),
            counterexampleSearch: search,
            templateID: templateID(for: candidate.type)?.rawValue,
            statsSummary: "引用 \(claim.citations.count) 段记录",
            sourceRevisions: revisions,
            holdoutValidatedPeriods: nil,
            capturedAt: now
        )
    }

    /// 周覆盖率：口径上收到 HoloKnowledgeIngestion.weeklyCoverage（发现桥与
    /// 财务规律挖矿共用同一确定性定义；此处保留转发兼容既有调用点）。
    static func weeklyCoverage(of dates: [Date]) -> Double? {
        HoloKnowledgeIngestion.weeklyCoverage(of: dates)
    }

    /// 为已发布候选的每个 claim 建版本化关联。
    static func linkages(
        findingID: UUID,
        runID: String,
        candidate: DiscoveryCandidate,
        atoms: [String: DiscoveryFactAtom],
        counterAtoms: [DiscoveryFactAtom],
        counterCoverageComplete: Bool,
        now: Date
    ) -> [DiscoveryClaimLinkage] {
        candidate.claims.map { claim in
            let semantic = semantic(for: claim, candidate: candidate)
            let evidence = evidenceSnapshot(
                for: claim,
                candidate: candidate,
                atoms: atoms,
                counterAtoms: counterAtoms,
                counterCoverageComplete: counterCoverageComplete,
                now: now
            )
            let domains = Array(Set((evidence.supportRefs + evidence.counterRefs).map(\.sourceDomain))).sorted()
            return DiscoveryClaimLinkage(
                findingID: findingID,
                runID: runID,
                candidateID: candidate.candidateID,
                claimID: claim.claimID,
                propositionID: HoloKnowledgeIdentity.propositionID(for: semantic),
                semanticDigest: semantic.semanticDigest,
                evidenceSnapshotID: evidence.id,
                semantic: semantic,
                evidenceSnapshot: evidence,
                domains: domains,
                createdAt: now
            )
        }
    }

    /// 发现侧授权范围：想法/任务/习惯三域，non_sensitive；八域记忆不扩大发现权限。
    static let discoveryAuthorizedDomains: Set<HoloMemoryDomain> = [.thought, .task, .habit]

    /// 用户「确认并记住」= 单次手动保存授权：形成方式仍是行为归纳（观察），
    /// 但用户确认绑定准确语义；不打开自动学习、不扩大为更广概括。
    static func revision(
        from linkage: DiscoveryClaimLinkage,
        now: Date
    ) -> HoloKnowledgeRevision {
        HoloKnowledgeRevision.make(
            semantic: linkage.semantic,
            topicLabel: linkage.semantic.displayText,
            domains: linkage.domains.isEmpty ? [.thought] : linkage.domains,
            sensitivity: .normal,
            partition: .normal,
            evidenceSnapshot: linkage.evidenceSnapshot,
            sourceAliases: [],
            origin: HoloKnowledgeOrigin(
                kind: .discoveryFinding,
                findingID: linkage.findingID.uuidString,
                runID: linkage.runID,
                candidateID: linkage.candidateID,
                claimID: linkage.claimID
            ),
            createdAt: now
        )
    }
}

