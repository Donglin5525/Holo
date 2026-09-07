//
//  HoloContextRetrievalService.swift
//  Holo
//
//  通用个人情境的混合检索（实施方案 §7）。
//
//  流程：访问策略已筛的 catalog → 混合候选合并（语义向量/主体对象/时间重叠/条件依赖/
//  会话来源，去重 ≤40，时间条件保份额）→ 生成用选取（≤8，须能改变结果）→
//  反证与本周期实例状态 → 覆盖标注（语义不可用时 degraded，仍返回基础方案）。
//  一次原文补查的预算常量在此定义，实际取文由 P6/P7 运行时执行。
//
//  纯逻辑（语义提供方协议注入），可 standalone 编译。
//

import Foundation

// MARK: - 语义检索提供方

/// 语义候选提供方（运行时接 embedding store + provider；无网络/不可用时抛错降级）。
nonisolated protocol HoloContextSemanticSearchProviding: Sendable {
    func semanticCandidateIDs(
        query: String,
        directions: [String]
    ) async throws -> [String: Double]
}

// MARK: - 检索结果

nonisolated struct HoloContextRetrievalResult: Equatable, Sendable {
    /// 合并去重后的候选（≤40）。
    var entries: [HoloContextCatalogEntry]
    /// 生成阶段选取（≤8；不要求补满）。
    var selected: [HoloContextCatalogEntry]
    var semanticCoverage: HoloContextSemanticCoverage
    /// 选取条目中存在反证记录的（contextID → 反证记录 ID）。
    var contradictions: [String: [String]]

    init(
        entries: [HoloContextCatalogEntry] = [],
        selected: [HoloContextCatalogEntry] = [],
        semanticCoverage: HoloContextSemanticCoverage = .full,
        contradictions: [String: [String]] = [:]
    ) {
        self.entries = entries
        self.selected = selected
        self.semanticCoverage = semanticCoverage
        self.contradictions = contradictions
    }
}

// MARK: - 服务

nonisolated struct HoloContextRetrievalService: Sendable {
    /// 合并候选上限（§7.1）。
    static let mergedEntryLimit = 40
    /// 生成阶段选取上限（§7.1）。
    static let selectionLimit = 8
    /// 向量独占名额上限：为时间/条件候选保留份额。
    static let semanticOnlyReserve = 30
    /// 一次原文补查预算（§7.1：最多 4 段、8,000 字符）。
    static let rawFallbackSegmentLimit = 4
    static let rawFallbackCharacterLimit = 8_000

    let semanticProvider: (any HoloContextSemanticSearchProviding)?

    init(semanticProvider: (any HoloContextSemanticSearchProviding)? = nil) {
        self.semanticProvider = semanticProvider
    }

    /// 混合检索主入口。catalog 必须已经过 HoloContextAccessPolicy 筛选。
    func retrieve(
        frame: HoloPlanningRequestFrame,
        catalog: [HoloContextAdviceCandidate],
        occurrences: [HoloContextOccurrence] = [],
        counterEvidenceByRecordID: [String: [String]] = [:],
        calendar: Calendar,
        now: Date
    ) async -> HoloContextRetrievalResult {
        // 1) 语义候选（不可用→降级词法，标注 degraded）。
        var semanticScores: [String: Double] = [:]
        var coverage: HoloContextSemanticCoverage = .full
        if let provider = semanticProvider {
            do {
                semanticScores = try await provider.semanticCandidateIDs(
                    query: frame.goalSummary.isEmpty ? frame.utterance : frame.goalSummary,
                    directions: frame.retrievalDirections
                )
            } catch {
                coverage = .degraded
            }
        } else {
            coverage = .degraded
        }
        // 降级词法召回：多查询词匹配（对象、方向词与 goal 词）。
        if coverage == .degraded {
            semanticScores = Self.lexicalScores(frame: frame, catalog: catalog)
        }

        // 2) 信号合并。
        var signals: [String: Set<HoloContextRetrievalSignal>] = [:]

        for candidate in catalog {
            var matched: Set<HoloContextRetrievalSignal> = []
            if semanticScores[candidate.recordID] != nil || semanticScores[candidate.versionID] != nil {
                matched.insert(.semantic)
            }
            if Self.partyMatches(frame: frame, payload: candidate.payload) {
                matched.insert(.partyMatch)
            }
            if let temporal = candidate.payload.temporal,
               HoloContextTemporalResolver.overlaps(
                   temporal: temporal,
                   rangeStart: now,
                   rangeEnd: now.addingTimeInterval(30 * 86_400),
                   now: now
               ),
               HoloContextTemporalResolver.isActive(temporal: temporal, at: now) {
                matched.insert(.temporalOverlap)
            }
            if Self.conditionMatches(frame: frame, payload: candidate.payload) {
                matched.insert(.conditionMatch)
            }
            signals[candidate.recordID] = matched
        }
        // 3) 合并去重（≤40；向量独占 ≤30 保时间/条件份额）。
        var entries: [HoloContextCatalogEntry] = []
        var semanticOnlyCount = 0
        let ranked = catalog
            .map { candidate -> (candidate: HoloContextAdviceCandidate, rank: Double) in
                let signalCount = Double(signals[candidate.recordID]?.count ?? 0)
                let semantic = semanticScores[candidate.recordID] ?? 0
                return (candidate, signalCount * 2 + semantic)
            }
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.candidate.recordID < rhs.candidate.recordID
                }
                return lhs.rank > rhs.rank
            }
        for (candidate, _) in ranked {
            guard let matched = signals[candidate.recordID], !matched.isEmpty else { continue }
            if entries.count >= Self.mergedEntryLimit { break }
            if matched == [.semantic] {
                if semanticOnlyCount >= Self.semanticOnlyReserve { continue }
                semanticOnlyCount += 1
            }
            // 本周期实例状态（推荐某时段≠拥有日程；完成不能当未做）。
            var currentStatus: HoloContextOccurrence.Status?
            if let temporal = candidate.payload.temporal,
               temporal.kind == .recurring,
               let recurrence = temporal.recurrence {
                let periodKey = HoloContextTemporalResolver.periodKey(
                    for: recurrence, at: now, calendar: calendar
                )
                currentStatus = HoloContextTemporalResolver.occurrenceStatus(
                    occurrences: occurrences,
                    contextID: candidate.payload.contextID,
                    periodKey: periodKey
                )
            }
            entries.append(HoloContextCatalogEntry(
                recordID: candidate.recordID,
                versionID: candidate.versionID,
                payload: candidate.payload,
                needsQualifiedExpression: candidate.needsQualifiedExpression,
                matchedBy: matched,
                currentOccurrenceStatus: currentStatus
            ))
        }

        // 4) 生成阶段选取（≤8）：信号数优先，推断类靠后（需要限定表达）。
        let selected = Array(
            entries
                .sorted { lhs, rhs in
                    let lhsRank = selectionRank(lhs)
                    let rhsRank = selectionRank(rhs)
                    if lhsRank == rhsRank { return lhs.recordID < rhs.recordID }
                    return lhsRank > rhsRank
                }
                .prefix(Self.selectionLimit)
        )

        // 5) 反证标注（选取条目）。
        var contradictions: [String: [String]] = [:]
        for entry in selected {
            if let counters = counterEvidenceByRecordID[entry.recordID], !counters.isEmpty {
                contradictions[entry.recordID] = counters
            }
        }

        return HoloContextRetrievalResult(
            entries: entries,
            selected: selected,
            semanticCoverage: coverage,
            contradictions: contradictions
        )
    }

    // MARK: - 信号判定

    private func selectionRank(_ entry: HoloContextCatalogEntry) -> Double {
        var rank = Double(entry.matchedBy.count) * 2
        if entry.matchedBy.contains(.temporalOverlap) { rank += 1 }
        if entry.matchedBy.contains(.partyMatch) { rank += 1 }
        if entry.needsQualifiedExpression { rank -= 0.5 }
        return rank
    }

    /// 主体/对象匹配：frame 文本中出现载荷主体或对象的归一化标签。
    static func partyMatches(frame: HoloPlanningRequestFrame, payload: HoloPersonalContextPayloadV1) -> Bool {
        let haystack = normalized([
            frame.utterance, frame.goalSummary, frame.scope ?? ""
        ].joined(separator: " "))
        for party in payload.subjects + payload.objects {
            let label = normalized(party.label)
            if label.count >= 2, haystack.contains(label) {
                return true
            }
        }
        return false
    }

    /// 条件/依赖匹配：范围条件词重叠或存在关联上下文。
    static func conditionMatches(frame: HoloPlanningRequestFrame, payload: HoloPersonalContextPayloadV1) -> Bool {
        if !payload.linkedContextIDs.isEmpty { return true }
        guard let condition = payload.applicability.conditionText else { return false }
        let conditionWords = tokenized(condition)
        let frameWords = tokenized([frame.utterance, frame.goalSummary, frame.scope ?? ""].joined(separator: " "))
        return !conditionWords.isDisjoint(with: frameWords)
    }

    /// 降级词法召回（§7.2：多查询词法召回，标记 degraded）。
    static func lexicalScores(
        frame: HoloPlanningRequestFrame,
        catalog: [HoloContextAdviceCandidate]
    ) -> [String: Double] {
        let queryText = [
            frame.goalSummary,
            frame.utterance,
            frame.scope ?? "",
            frame.timeRangeExpression ?? ""
        ]
        + frame.retrievalDirections
        + frame.successConditions
        + frame.existingArrangements
        + frame.unknowns
        let queryWords = tokenized(queryText.joined(separator: " "))
        var scores: [String: Double] = [:]
        for candidate in catalog {
            let text = normalized(candidate.payload.statement + " " + candidate.payload.relationText)
            let overlap = tokenized(text).intersection(queryWords)
            if !overlap.isEmpty {
                scores[candidate.recordID] = min(Double(overlap.count) / 6.0, 1.0)
            }
        }
        return scores
    }

    // MARK: - 工具

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 分词：CJK 按字切 + 西文按词（词法召回的多查询词基础）。
    static func tokenized(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar.value > 0x2E80 {
                if !current.isEmpty {
                    tokens.insert(current.lowercased())
                    current = ""
                }
                tokens.insert(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty {
                    tokens.insert(current.lowercased())
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            tokens.insert(current.lowercased())
        }
        return tokens
    }
}
