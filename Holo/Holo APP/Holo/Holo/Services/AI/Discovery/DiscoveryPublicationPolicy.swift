//
//  DiscoveryPublicationPolicy.swift
//  Holo
//
//  「一个发现」本地发布策略（实施包 02 §8 不加第三轮润色 + D09 去重/否定/时效）。
//  纯逻辑：候选→核验→反例→计数→否定指纹→本地历史 全部作为输入注入；
//  输出最多一条可发布 payload 或结构化拒绝原因。不染网络与存储。
//

import Foundation

/// 发布门禁输入快照（Coordinator 组装）。
nonisolated struct DiscoveryPublicationInput: Sendable {
    let runID: String
    let freezeDigest: String
    /// 已通过结构门禁且核验 accept 的候选（claim 文案在此刻冻结，发布原样组装）。
    let acceptedCandidates: [AcceptedCandidate]
    /// 每候选的反例覆盖（repeat/change 覆盖不完整默认不发布，02 §6 末段）。
    let counterCoverage: [String: DiscoveryCounterCoverageState]
    /// 每候选的独立事件证据批次（计数口径）。
    let evidence: [String: DiscoveryEvidenceSummary]
    /// 仍在生效的否定指纹集合（store.hasNegativeFeedback 的批量结果）。
    let negativeFingerprints: Set<String>
    /// 当前已展示/历史发现的主题指纹（新增信息排序用 + 语义去重）。
    let recentSubjectFingerprints: Set<String>
    let now: Date
}

nonisolated struct AcceptedCandidate: Sendable {
    let candidate: DiscoveryCandidate
    let verification: DiscoveryCandidateResult
    /// 核验输入时反例块的实际数量（0 且覆盖 complete = 搜索完成无命中）。
    let counterEvidenceCount: Int
}

/// 独立事件计数摘要（EvidenceBatch 的门禁视图）。
nonisolated struct DiscoveryEvidenceSummary: Sendable {
    /// 独立 lineage 组数（ambiguous 不计）。
    let independentEventCount: Int
    /// 独立组的发生时间（已有发生时间的组；缺发生时间不能支持精确时序）。
    let independentEventDates: [Date]
    /// 这些组覆盖的不同「日」（上海时区自然日）。
    let independentDayCount: Int
}

nonisolated enum DiscoveryPublicationOutcome: Sendable {
    case publish(DiscoveryPublishedPayload)
    case rejectAll([DiscoveryRejection])

    var isPublish: Bool {
        if case .publish = self { return true }
        return false
    }
}

nonisolated struct DiscoveryRejection: Sendable, Equatable {
    let candidateID: String
    let reason: DiscoveryPublicationRejectionReason
}

nonisolated enum DiscoveryPublicationRejectionReason: Sendable, Equatable {
    case notAcceptedByVerification
    case insufficientIndependentEvents(required: Int, actual: Int)
    case boundedPatternSpanTooShort(days: Double)
    case coverageIncomplete
    case sensitivityNotResolved
    case userNegated
    case duplicateOfRecentFinding
    case missingEventDates
}

nonisolated final class DiscoveryPublicationPolicy {

    /// 首发类型门槛（02 §5 门禁 4 的发布侧复核；结构门禁已查，此处以证据计数为准）。
    struct TypeThresholds: Sendable {
        var twoEpisodesEvents = 2
        var boundedPatternEvents = 3
        var boundedPatternDays: Double = 7
        var boundedPatternPeriods = 2
        var changeOverTimeEventsPerPeriod = 2
        init() {}
    }

    /// 发现主题指纹（subjectKey 归一化；与否定指纹共用归一口径但盐域不同——
    /// 否定指纹按用户反馈材料计算，主题指纹按 candidate.subjectKey）。
    static func subjectFingerprint(of candidate: DiscoveryCandidate) -> String {
        "subject:\(candidate.subjectKey)"
    }

    let thresholds: TypeThresholds

    init(thresholds: TypeThresholds = TypeThresholds()) {
        self.thresholds = thresholds
    }

    func decide(_ input: DiscoveryPublicationInput) -> DiscoveryPublicationOutcome {
        var survivors: [(candidate: DiscoveryCandidate, rank: DiscoveryRankingFactors)] = []
        var rejections: [DiscoveryRejection] = []

        for accepted in input.acceptedCandidates {
            let candidate = accepted.candidate
            let id = candidate.candidateID

            // 核验必须 accept 且所有展示句 supported（结构层已保证 accept ⇒ 全 supported，
            // 这里防御性复核核验结果归属——串候选的核验结果不接受）
            guard accepted.verification.verdict == .accept,
                  accepted.verification.candidateID == id else {
                rejections.append(.init(candidateID: id, reason: .notAcceptedByVerification))
                continue
            }

            // 敏感边界：仅 non_sensitive 可发布；uncertain 一律拒绝（02 §4）
            guard candidate.sensitivity == .nonSensitive else {
                rejections.append(.init(candidateID: id, reason: .sensitivityNotResolved))
                continue
            }

            // 用户否定抑制（D09）：同主题否定 → 不再展示
            let fingerprint = Self.subjectFingerprint(of: candidate)
            guard !input.negativeFingerprints.contains(fingerprint) else {
                rejections.append(.init(candidateID: id, reason: .userNegated))
                continue
            }

            // 语义去重（D09）：与近期已展示发现同主题 → 不重复推送
            guard !input.recentSubjectFingerprints.contains(fingerprint) else {
                rejections.append(.init(candidateID: id, reason: .duplicateOfRecentFinding))
                continue
            }

            // 反例覆盖（02 §6 末段）：repeat/change 覆盖不完整不发布；
            // two_episodes 可发布但正文必须带范围限定（由 payload 组装保证）
            let coverage = input.counterCoverage[id] ?? .insufficientHistoryOrIndex
            if candidate.type != .twoEpisodes, coverage != .complete, coverage != .completedNoHit {
                rejections.append(.init(candidateID: id, reason: .coverageIncomplete))
                continue
            }

            // 独立事件计数（以证据为准，不信模型自述）
            guard let evidence = input.evidence[id] else {
                rejections.append(.init(candidateID: id, reason: .insufficientIndependentEvents(required: thresholds.twoEpisodesEvents, actual: 0)))
                continue
            }
            switch candidate.type {
            case .twoEpisodes:
                guard evidence.independentEventCount >= thresholds.twoEpisodesEvents else {
                    rejections.append(.init(id, .insufficientIndependentEvents(required: thresholds.twoEpisodesEvents, actual: evidence.independentEventCount)))
                    continue
                }
                guard evidence.independentEventDates.count >= thresholds.twoEpisodesEvents else {
                    // 只有两次经历但缺发生时间 → 不能成立「两次」的时序联系
                    rejections.append(.init(candidateID: id, reason: .missingEventDates))
                    continue
                }
            case .boundedPattern:
                guard evidence.independentEventCount >= thresholds.boundedPatternEvents else {
                    rejections.append(.init(candidateID: id, reason: .insufficientIndependentEvents(required: thresholds.boundedPatternEvents, actual: evidence.independentEventCount)))
                    continue
                }
                guard evidence.independentDayCount >= thresholds.boundedPatternPeriods else {
                    rejections.append(.init(candidateID: id, reason: .insufficientIndependentEvents(required: thresholds.boundedPatternEvents, actual: evidence.independentEventCount)))
                    continue
                }
                if let span = evidence.independentEventDates.min().map({ min in evidence.independentEventDates.max()!.timeIntervalSince(min) }),
                   span < thresholds.boundedPatternDays * 24 * 3600 {
                    rejections.append(.init(candidateID: id, reason: .boundedPatternSpanTooShort(days: span / 24 / 3600)))
                    continue
                }
            case .changeOverTime:
                guard evidence.independentEventCount >= thresholds.changeOverTimeEventsPerPeriod * 2,
                      evidence.independentDayCount >= 2 else {
                    rejections.append(.init(candidateID: id, reason: .insufficientIndependentEvents(required: thresholds.changeOverTimeEventsPerPeriod * 2, actual: evidence.independentEventCount)))
                    continue
                }
            }

            // 排序因子（02 §8：覆盖可靠性 → 个人相关 → 新增信息 → 时效 → 反馈偏好；确定性）
            let rank = DiscoveryRankingFactors(
                coverageReliability: coverage == .complete ? 2 : (coverage == .completedNoHit ? 1 : 0),
                counterEvidenceCount: accepted.counterEvidenceCount,
                isNewSubject: !input.recentSubjectFingerprints.contains(fingerprint),
                recency: candidate.timeRange.start ?? candidate.timeRange.end ?? "",
                candidateID: id
            )
            survivors.append((candidate, rank))
        }

        guard let best = survivors.max(by: { lhs, rhs in lhs.1 < rhs.1 }) else {
            return .rejectAll(rejections)
        }
        let payload = Self.assemblePayload(
            candidate: best.candidate,
            runID: input.runID,
            freezeDigest: input.freezeDigest,
            now: input.now
        )
        return .publish(payload)
    }

    /// 已核验标题/正文 claim 原样组装；不删任何限定词（02 §8）。
    /// 覆盖说明由程序生成，区分「当前记录范围内未发现反例」与「检索受限」。
    static func assemblePayload(
        candidate: DiscoveryCandidate,
        runID: String,
        freezeDigest: String,
        now: Date
    ) -> DiscoveryPublishedPayload {
        let titleClaim = candidate.claims.first { $0.claimID == candidate.titleClaimID }
        let bodyClaims = candidate.bodyClaimIDs.compactMap { id in
            candidate.claims.first { $0.claimID == id }
        }
        let citations = candidate.claims.flatMap(\.citations).map { citation in
            DiscoveryPublishedPayload.Citation(
                evidenceID: citation.evidenceID,
                quote: citation.quote,
                sourceRef: "" // 由 Coordinator 用 retrievalIndex 回填真实 sourceRef
            )
        }
        return DiscoveryPublishedPayload(
            candidateID: candidate.candidateID,
            type: candidate.type,
            title: titleClaim?.text ?? "",
            body: bodyClaims.map(\.text),
            citations: citations,
            coverageNote: coverageNote(for: candidate),
            sensitivity: candidate.sensitivity,
            timeRange: candidate.timeRange,
            fingerprintMaterial: subjectFingerprint(of: candidate)
        )
    }

    /// 覆盖/范围说明：变化类必须体现两个对比区间；限定语不得删除。
    static func coverageNote(for candidate: DiscoveryCandidate) -> String {
        switch candidate.type {
        case .twoEpisodes:
            return "范围：这两段记录的范围，不代表经常如此。"
        case .boundedPattern:
            return "范围：检索到的记录区间内反复出现；未发现相反记录，但仅覆盖已记录的部分。"
        case .changeOverTime:
            let periods = candidate.comparisonPeriods
            guard periods.count == 2 else {
                return "范围：两个可比时段的记录。"
            }
            func text(_ range: DiscoveryTimeRange) -> String {
                (range.start ?? "?") + " 至 " + (range.end ?? "?")
            }
            return "对比区间：\(text(periods[0])) 与 \(text(periods[1]))，仅基于这两个时段的记录。"
        }
    }
}

/// 确定性排序因子（全部可比较字段；candidateID 兜底打破平局，保证多次运行同序）。
nonisolated struct DiscoveryRankingFactors: Sendable, Comparable {
    let coverageReliability: Int
    let counterEvidenceCount: Int
    let isNewSubject: Bool
    let recency: String
    let candidateID: String

    static func < (lhs: DiscoveryRankingFactors, rhs: DiscoveryRankingFactors) -> Bool {
        if lhs.coverageReliability != rhs.coverageReliability {
            return lhs.coverageReliability < rhs.coverageReliability
        }
        if lhs.counterEvidenceCount != rhs.counterEvidenceCount {
            return lhs.counterEvidenceCount < rhs.counterEvidenceCount
        }
        if lhs.isNewSubject != rhs.isNewSubject {
            return rhs.isNewSubject // 新主题优先
        }
        if lhs.recency != rhs.recency {
            return lhs.recency < rhs.recency
        }
        return lhs.candidateID < rhs.candidateID
    }
}

nonisolated private extension DiscoveryRejection {
    init(_ candidateID: String, _ reason: DiscoveryPublicationRejectionReason) {
        self.init(candidateID: candidateID, reason: reason)
    }
}
