//
//  HoloReportSourceAdapter.swift
//  Holo
//
//  两类报告 → 统一 ReportDescriptor（P0 文档 §1 五条轨道归一）。
//  - 周期回放：memoryInsightDidGenerate 通知（本地/云端同源）/ 冷启动档案重扫；
//  - 深度分析：agentReportDidFinalize 通知（本地+云端 finalize 统一落点）/
//    冷启动 agentResultJSON 重扫；云端轨道带结构化信封，本地轨道由 rendered 推导。
//  - 云端证据引用机制（与 HoloCloudEvidencePresenter.citedEvidence 同一事实）：
//    claims.evidenceIDs 引用的是 metric 证据的 metricKey；rows 证据无 ID，
//    按「被引用指标所属数据集」关联。
//  - 锚点与日常萃取同词表（financeCategory/habit/…），值取证据分组名或
//    回放主题键——同命题跨链路按稳定 ID 自然归并（R31/R08）。
//

import Foundation

nonisolated enum HoloReportSourceAdapter {

    // MARK: - 周期回放（通知与档案共用同一投影）

    static func replayDescriptor(
        insightID: String,
        payload: MemoryInsightPayload,
        periodStart: Date,
        periodEnd: Date,
        sourceSnapshotHash: String?
    ) -> HoloReportDescriptor {
        let claims = payload.cards.compactMap { card -> HoloReportClaim? in
            // 无 memoryCandidate 的卡片（overview/anomaly/crossDomain 等）→ 历史查阅级，
            // 不产候选（P0 决策）；主体锚点缺失的 claim 也无法通过记忆 Schema 校验。
            guard let mc = card.memoryCandidate,
                  let domain = replayCardDomain(card) else { return nil }
            return HoloReportClaim(
                claimID: card.id,
                claimType: replayClaimType(mc.semanticType),
                displayText: mc.displaySummary,
                aiUsableText: mc.aiUseSummary,
                interpretation: nil,
                evidenceIDs: card.evidence.indices.map { "insight:\(insightID):\(card.id):ev\($0)" },
                metricAssertions: [],
                domain: domain,
                anchors: [HoloReportAnchorHint(
                    type: domainAnchorType(domain),
                    value: mc.subjectKey
                )],
                sampleCount: card.evidence.count,
                conditions: []
            )
        }
        return HoloReportDescriptor(
            canonicalReportID: "replay-\(insightID)",
            sourceKind: .periodReplay,
            sourceRecordID: insightID,
            reportRevisionDigest: revisionDigest(claims: claims),
            parentReportID: nil,
            rootReportID: nil,
            sourceSnapshotHash: sourceSnapshotHash,
            generatedAt: Date(),
            periodStart: periodStart,
            periodEnd: periodEnd,
            domains: Array(Set(claims.map(\.domain))).sorted(),
            truncated: false,
            coverageNote: nil,
            claims: claims,
            usedMemoryIDs: payload.usedMemoryIDs ?? [],
            status: .ready
        )
    }

    /// 回放语义类型 → 统一 claimType 词表。
    private static func replayClaimType(_ semanticType: String) -> String {
        switch semanticType {
        case "phaseShift": return "change"
        case "stablePattern", "driftSignal": return "pattern"
        case "lifeEvent", "statMilestone": return "observation"
        default: return "observation"
        }
    }

    /// 回放卡片领域：memoryCandidate 仅在 habit/finance/task/milestone 四类卡上产生
    /// （MemoryInsightModels 文档注释）；其余类型返回 nil 由调用方跳过。
    private static func replayCardDomain(_ card: MemoryInsightCard) -> HoloMemoryDomain? {
        switch card.type {
        case .habit: return .habit
        case .finance: return .finance
        case .task: return .task
        case .milestone: return .goal
        case .thought, .crossDomain, .overview, .anomaly: return nil
        }
    }

    // MARK: - 深度分析（结构化信封优先，本地轨道由 rendered 推导）

    static func analysisDescriptor(
        messageID: String,
        rendered: HoloRenderedAgentResult,
        now: Date = Date()
    ) -> HoloReportDescriptor {
        // 云端轨道：finalizeCloudResult 落的结构化信封；本地轨道：由 rendered 合成。
        let envelope = rendered.reportUnderstanding ?? renderedEnvelope(from: rendered)
        let claims = envelope.claims
        let domains = Array(Set(claims.map(\.domain))).sorted()
        let parent = rendered.lineage?.parentResultID
        return HoloReportDescriptor(
            canonicalReportID: "analysis-\(messageID)",
            sourceKind: .deepAnalysis,
            sourceRecordID: messageID,
            reportRevisionDigest: revisionDigest(claims: claims),
            parentReportID: parent.map { "analysis-\($0)" },
            rootReportID: nil,
            sourceSnapshotHash: nil,
            generatedAt: now,
            periodStart: envelope.taskRangeStart.map { Date(timeIntervalSince1970: $0) },
            periodEnd: envelope.taskRangeEnd.map { Date(timeIntervalSince1970: $0) },
            domains: domains.isEmpty ? [.conversation] : domains,
            truncated: envelope.truncated,
            coverageNote: envelope.coverageNote,
            claims: claims,
            usedMemoryIDs: envelope.usedMemoryIDs,
            status: .ready
        )
    }

    /// 本地深度分析轨道（无结构化信封）：由章节推导观察级 claim；证据=报告级
    /// 引用池（独立性 unknown，不提升稳定度）；section.kind 为云端规范化 claim 类型。
    private static func renderedEnvelope(
        from rendered: HoloRenderedAgentResult
    ) -> HoloReportUnderstandingEnvelope {
        let materialIDs = rendered.evidenceReferences.map(\.id)
        let claims = rendered.sections.enumerated().compactMap { index, section -> HoloReportClaim? in
            let text = section.body.isEmpty ? section.title : section.body
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return HoloReportClaim(
                claimID: "section-\(index)",
                claimType: section.kind ?? "observation",
                displayText: section.title,
                aiUsableText: text,
                interpretation: section.interpretation,
                evidenceIDs: materialIDs,
                metricAssertions: [],
                domain: .conversation,
                anchors: [HoloReportAnchorHint(type: .userTheme, value: section.title)],
                sampleCount: nil,
                conditions: []
            )
        }
        let materials = rendered.evidenceReferences.map { reference in
            HoloReportEvidenceMaterial(
                evidenceID: reference.id,
                kind: reference.metricValue != nil ? "metric" : "rows",
                metricKey: reference.id.hasPrefix("cloud-") ? nil : reference.id,
                dataset: reference.datasetName,
                group: nil,
                value: reference.metricValue,
                unit: reference.metricUnit,
                sourceCount: nil,
                count: nil,
                excerpts: [reference.summary]
            )
        }
        return HoloReportUnderstandingEnvelope(
            claims: claims,
            evidence: materials,
            taskRangeStart: nil,
            taskRangeEnd: nil,
            truncated: false,
            coverageNote: rendered.scope?.truncatedNote,
            usedMemoryIDs: []
        )
    }

    // MARK: - 云端结构化信封组装（finalizeCloudResult 调用）

    static func envelope(
        claims: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudClaim],
        evidence: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence],
        taskRangeStart: Double?,
        taskRangeEnd: Double?,
        truncated: Bool,
        coverageNote: String?,
        usedMemoryIDs: [String]
    ) -> HoloReportUnderstandingEnvelope {
        let metricsByKey = Dictionary(
            evidence.filter { ($0.kind ?? "metric") != "rows" && $0.metricKey != nil }
                .map { ($0.metricKey!, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let projectedClaims = claims.compactMap { claim -> HoloReportClaim? in
            guard let text = (claim.displayText ?? claim.summary)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let cited = (claim.evidenceIDs ?? []).compactMap { metricsByKey[$0] }
            // 数据证据为空的 claim：若引用了旧记忆则整条跳过（R06 防循环），
            // 否则也无从核验 → 均不进事实库。
            guard !cited.isEmpty else { return nil }
            let domains = Set(cited.compactMap(\.dataset).map(Self.datasetDomain))
            // 混域/未知域 → 无法归属，保守跳过（R07 同域不可误并的另一面）
            guard domains.count == 1, let domain = domains.first else { return nil }
            return HoloReportClaim(
                claimID: claim.id ?? "claim-\(stableHash(text))",
                claimType: claim.type ?? "observation",
                displayText: claim.claimTitle ?? claim.summary ?? text,
                aiUsableText: text,
                interpretation: claim.interpretation,
                evidenceIDs: cited.compactMap(\.metricKey),
                metricAssertions: (claim.metricAssertions ?? []).map { assertion in
                    HoloReportMetricAssertion(
                        metricKey: assertion.metricKey,
                        value: assertion.value,
                        baselineValue: assertion.baselineValue,
                        unit: assertion.unit,
                        comparison: assertion.comparison,
                        evidenceIDs: assertion.evidenceIDs ?? []
                    )
                },
                domain: domain,
                anchors: claimAnchors(domain: domain, cited: cited),
                sampleCount: cited.compactMap(\.sourceCount).max(),
                conditions: []
            )
        }

        let citedKeys = Set(projectedClaims.flatMap(\.evidenceIDs))
        let citedDatasets = Set(citedKeys.compactMap { metricsByKey[$0]?.dataset })
        var materials = evidence
            .filter { item in
                if let key = item.metricKey { return citedKeys.contains(key) }
                if let dataset = item.dataset { return citedDatasets.contains(dataset) }
                return false
            }
            .map { item in
                HoloReportEvidenceMaterial(
                    evidenceID: item.metricKey ?? "rows:\(item.dataset ?? "unknown")",
                    kind: item.kind ?? "metric",
                    metricKey: item.metricKey,
                    dataset: item.dataset,
                    group: item.group,
                    value: item.value,
                    unit: item.unit,
                    sourceCount: item.sourceCount,
                    count: item.count,
                    excerpts: Array((item.excerpts ?? []).prefix(3))
                )
            }
        materials = Array(Dictionary(
            materials.map { ($0.evidenceID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values)

        return HoloReportUnderstandingEnvelope(
            claims: projectedClaims,
            evidence: materials,
            taskRangeStart: taskRangeStart,
            taskRangeEnd: taskRangeEnd,
            truncated: truncated,
            coverageNote: coverageNote,
            usedMemoryIDs: usedMemoryIDs
        )
    }

    /// claim 锚点：主证据的分组名 → 实体锚；无分组名回退指标键主题锚。
    /// 单锚为主（与日常萃取单实体锚身份对齐，最大化 R31 归并概率）。
    private static func claimAnchors(
        domain: HoloMemoryDomain,
        cited: [HoloCloudAnalysisClient.StatusResponse.CloudResult.CloudEvidence]
    ) -> [HoloReportAnchorHint] {
        let primary = cited.first
        let group = primary?.group?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let group, !group.isEmpty {
            return [HoloReportAnchorHint(type: domainAnchorType(domain), value: group)]
        }
        if let metricKey = primary?.metricKey {
            return [HoloReportAnchorHint(type: domainAnchorType(domain), value: metricKey)]
        }
        return [HoloReportAnchorHint(type: .userTheme, value: domain.rawValue)]
    }

    /// 数据集名前缀 → 领域（finance.transactions / habit.daily / health.steps…）。
    static func datasetDomain(_ dataset: String) -> HoloMemoryDomain {
        let prefix = dataset.split(separator: ".").first.map(String.init) ?? dataset
        switch prefix {
        case "finance": return .finance
        case "health": return .health
        case "habit": return .habit
        case "task": return .task
        case "goal": return .goal
        case "thought": return .thought
        default: return .conversation
        }
    }

    /// 领域 → 实体锚类型（与日常萃取信号锚点同一词表，R31）。
    static func domainAnchorType(_ domain: HoloMemoryDomain) -> HoloMemoryAnchorType {
        switch domain {
        case .finance: return .financeCategory
        case .habit: return .habit
        case .task: return .task
        case .goal: return .goal
        case .thought: return .thoughtTopic
        case .health: return .healthMetric
        case .conversation: return .userTheme
        case .profile: return .profile
        }
    }

    // MARK: - 公共工具

    /// revision 摘要：只含结论正文+证据引用+数字断言；不含标题排版（R03）。
    static func revisionDigest(claims: [HoloReportClaim]) -> String {
        let canonical = claims
            .map { claim in
                [
                    claim.claimType,
                    claim.aiUsableText,
                    claim.evidenceIDs.joined(separator: ","),
                    claim.metricAssertions.map { "\($0.metricKey)=\($0.value ?? 0)" }
                        .joined(separator: ","),
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        return String(stableHash(canonical), radix: 16)
    }

    /// 进程间稳定的 64 位散列（Swift hashValue 每次启动随机化，禁用于身份）。
    static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 深度分析报告落消息后广播（ChatMessageRepository.finalizeAgentMessage 统一发出，
    /// 本地/云端两条轨道共用；报告理解链路据此登记待处理项）。
    static let agentReportDidFinalize = Notification.Name("agentReportDidFinalize")
}
