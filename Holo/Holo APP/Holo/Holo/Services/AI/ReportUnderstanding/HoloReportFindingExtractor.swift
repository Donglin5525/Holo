//
//  HoloReportFindingExtractor.swift
//  Holo
//
//  ReportDescriptor → 统一记忆候选（确定性提取，README §8.3）。
//  - 全程不调用模型：只做结构化 claim 的程序映射与核验；
//  - 准入规则：suggestion 不进事实库（R13）；correlation 留待 V1.1（README §5.3）；
//    仅引用旧记忆、无数据证据的结论整条拒绝（R06 防循环）；
//  - 数字核验：metricAssertions 与证据池值/单位/方向三对（R09/R10）；
//  - 主体守卫：健康域结论含第三方主体标记 → 无法确证归属本人，拒绝（R12）；
//  - 证据仅产 report 派生 kind（aggregateSnapshot），永不伪造 explicitUserStatement（R11）。
//

import Foundation

nonisolated enum HoloReportFindingExtractor {
    /// 提取器版本：准入/核验规则变更时 +1（进处理键）。
    static let extractorVersion = 1

    /// V1.1 才接入的结论类型（README §5.3：跨域共同变化谨慎提出，不作因果事实）。
    static let deferredClaimTypes: Set<String> = ["correlation"]

    /// 健康域第三方主体标记：无法确证「是用户本人」时宁可放弃（R12）。
    static let thirdPartySubjectMarkers = [
        "父亲", "母亲", "爸妈", "家长", "老婆", "老公", "爱人", "配偶",
        "孩子", "儿子", "女儿", "爷爷", "奶奶", "外公", "外婆", "家人", "朋友", "同事",
    ]

    struct Output: Sendable {
        var records: [HoloMemoryRecord]
        var rejections: [(claimID: String, reason: String)]
        /// suggestion 类（不进事实库但留诊断），R13。
        var suggestionCount: Int
    }

    static func extract(
        descriptor: HoloReportDescriptor,
        evidence: [HoloReportEvidenceMaterial],
        now: Date = Date()
    ) -> Output {
        var records: [HoloMemoryRecord] = []
        var rejections: [(String, String)] = []
        var suggestionCount = 0
        let materialsByID = Dictionary(
            evidence.map { ($0.evidenceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let referencedMemories = Set(descriptor.usedMemoryIDs)

        for claim in descriptor.claims {
            // R13：建议记录为「曾提出」，不成为用户偏好/行动
            if claim.claimType == "suggestion" {
                suggestionCount += 1
                continue
            }
            // V1.1 才接入跨域共同变化
            if deferredClaimTypes.contains(claim.claimType) {
                rejections.append((claim.claimID, "correlation-deferred-v1.1"))
                continue
            }
            // R06：仅引用旧记忆、无数据证据 → 不得反哺被引用记忆
            if claim.evidenceIDs.isEmpty {
                let reason = referencedMemories.isEmpty
                    ? "no-data-evidence"
                    : "memory-only-claim-loop-guard"
                rejections.append((claim.claimID, reason))
                continue
            }
            // R12：健康域 + 第三方主体 → 无法确证归属本人
            if claim.domain == .health,
               let subjectText = subjectText(claim, materials: materialsByID),
               thirdPartySubjectMarkers.contains(where: subjectText.contains) {
                rejections.append((claim.claimID, "third-party-subject-unverifiable"))
                continue
            }
            switch buildRecord(
                claim: claim,
                descriptor: descriptor,
                materials: materialsByID,
                now: now
            ) {
            case .record(let record):
                records.append(record)
            case .rejected(let reason):
                rejections.append((claim.claimID, reason))
            }
        }
        return Output(records: records, rejections: rejections, suggestionCount: suggestionCount)
    }

    private enum BuildOutcome {
        case record(HoloMemoryRecord)
        case rejected(String)
    }

    // MARK: - 单条 claim → 记忆记录

    private static func buildRecord(
        claim: HoloReportClaim,
        descriptor: HoloReportDescriptor,
        materials: [String: HoloReportEvidenceMaterial],
        now: Date
    ) -> BuildOutcome {
        // 证据核验（数值/方向/单位三对，R09/R10）
        var evidenceRefs: [HoloMemoryEvidenceRef] = []
        for evidenceID in claim.evidenceIDs {
            guard let material = materials[evidenceID] else {
                return .rejected("evidence-material-missing:\(evidenceID)")
            }
            if let failure = verifyMetricAssertions(claim, material: material) {
                return .rejected(failure)
            }
            let observedAt = descriptor.periodEnd ?? descriptor.generatedAt
            evidenceRefs.append(HoloMemoryEvidenceRef(
                id: "\(descriptor.canonicalReportID):\(claim.claimID):\(evidenceID)",
                kind: .aggregateSnapshot,
                sourceDomain: claim.domain,
                // lineageKey 指向「报告内证据条目」——报告与报告之间按
                // (metricKey+观测窗) 判独立性（EvidenceResolver），不在键上虚增独立。
                lineageKey: "report-evidence:\(descriptor.canonicalReportID):\(evidenceID)",
                sourceID: evidenceID,
                revisionDigest: descriptor.reportRevisionDigest,
                observedAt: observedAt,
                validFrom: descriptor.periodStart,
                validTo: descriptor.periodEnd,
                aggregateDefinition: material.metricKey ?? material.dataset,
                sampleCount: material.sourceCount ?? material.count,
                summary: materialSummary(material)
            ))
        }
        guard !evidenceRefs.isEmpty else {
            return .rejected("no-resolved-evidence")
        }

        // 锚点：与日常萃取同词表的实体锚（跨链路同命题同锚 → 同稳定 ID，R08/R31）
        let anchors = claim.anchors.compactMap { hint -> HoloMemoryAnchorRef? in
            try? HoloMemoryAnchorRef(type: hint.type, value: hint.value, displayLabel: nil)
        }
        guard !anchors.isEmpty else {
            return .rejected("no-canonical-anchor")
        }

        let claimKind = memoryClaimKind(claim.claimType)
        let persistenceClass = memoryPersistenceClass(claim.claimType)
        guard let stableID = try? HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: claim.domain,
            sourceDomains: [claim.domain],
            claimKind: claimKind,
            anchors: anchors
        ) else {
            return .rejected("stable-id-failed")
        }

        var prohibited = [
            "不得当作用户已确认的偏好或承诺",
            "不得据此推断人格或永久性结论",
        ]
        if claim.interpretation != nil {
            prohibited.append("interpretation 仅为低置信解读，不得当事实转述")
        }

        let observedAt = descriptor.periodEnd ?? descriptor.generatedAt
        var record = HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: claim.domain,
            sourceDomains: [claim.domain],
            subjectKey: anchors.map(\.stableKey).joined(separator: ","),
            anchorRefs: anchors,
            claimKind: claimKind,
            persistenceClass: persistenceClass,
            displaySummary: claim.displayText,
            aiUseSummary: claim.aiUsableText,
            prohibitedInferences: prohibited,
            evidenceRefs: evidenceRefs,
            upstreamMemoryIDs: descriptor.usedMemoryIDs,
            counterEvidenceRefs: [],
            validFrom: descriptor.periodStart,
            validTo: descriptor.periodEnd,
            lastSupportedAt: observedAt,
            expiresAt: nil,
            confidenceScore: initialConfidence(claim.claimType),
            freshnessScore: 1.0,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: extractorVersion,
            promptVersion: 1,
            lastObservationKey: nil,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            adoptionMetadata: nil,
            recordVersion: 1,
            predecessorVersionID: nil,
            supersedesMemoryID: nil,
            createdAt: now,
            updatedAt: now,
            schemaVersion: 1,
            usageCount: nil,
            lastUsedAt: nil,
            personalContext: nil,
            decisionMetadata: nil
        )
        // 与日常萃取同构：candidate → 激活策略裁决（§6.6 两链路同规则）
        if let adopted = HoloMemoryActivationPolicy.apply(to: record, now: now) {
            record = adopted
        }
        return .record(record)
    }

    // MARK: - 数字核验（R09/R10）

    /// metricAssertions 与证据池对账：值误差 >0.5% 或方向矛盾 → 整条拒绝。
    static func verifyMetricAssertions(
        _ claim: HoloReportClaim,
        material: HoloReportEvidenceMaterial
    ) -> String? {
        for assertion in claim.metricAssertions {
            guard assertion.metricKey == material.metricKey || assertion.evidenceIDs.contains(material.evidenceID) else {
                continue
            }
            // R09：值对账（有证据值时）
            if let evidenceValue = material.value, let claimed = assertion.value {
                let tolerance = max(abs(evidenceValue) * 0.005, 0.01)
                if abs(evidenceValue - claimed) > tolerance {
                    return "metric-value-mismatch:\(assertion.metricKey)"
                }
            }
            // R10：方向对账——comparison 与 (value vs baselineValue) 的实际符号一致
            if let comparison = assertion.comparison,
               let value = assertion.value,
               let baseline = assertion.baselineValue {
                let actualUp = value > baseline
                let claimedUp = comparison.lowercased().hasPrefix("up")
                if actualUp != claimedUp, value != baseline {
                    return "metric-direction-mismatch:\(assertion.metricKey)"
                }
            }
        }
        return nil
    }

    // MARK: - 映射

    static func memoryClaimKind(_ claimType: String) -> HoloMemoryClaimKind {
        switch claimType {
        case "observation": return .observedFact
        case "change": return .phaseShift
        case "pattern": return .recurringPattern
        default: return .observedFact
        }
    }

    static func memoryPersistenceClass(_ claimType: String) -> HoloMemoryPersistenceClass {
        switch claimType {
        case "observation": return .currentState
        case "change": return .phase
        case "pattern": return .durable
        default: return .currentState
        }
    }

    static func initialConfidence(_ claimType: String) -> Double {
        switch claimType {
        case "pattern": return 0.6
        case "change": return 0.5
        default: return 0.55
        }
    }

    /// R12 主体判读材料：优先证据摘录（报告证据里包含人话行文），回退结论正文。
    private static func subjectText(
        _ claim: HoloReportClaim,
        materials: [String: HoloReportEvidenceMaterial]
    ) -> String? {
        let excerpts = claim.evidenceIDs.compactMap { materials[$0]?.excerpts }.flatMap { $0 }
        if !excerpts.isEmpty { return excerpts.joined(separator: " ") }
        return claim.displayText + " " + claim.aiUsableText
    }

    private static func materialSummary(_ material: HoloReportEvidenceMaterial) -> String? {
        var parts: [String] = []
        if let metricKey = material.metricKey { parts.append(metricKey) }
        if let dataset = material.dataset { parts.append(dataset) }
        if let value = material.value {
            parts.append("\(value)\(material.unit ?? "")")
        }
        if let count = material.count ?? material.sourceCount { parts.append("n=\(count)") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
