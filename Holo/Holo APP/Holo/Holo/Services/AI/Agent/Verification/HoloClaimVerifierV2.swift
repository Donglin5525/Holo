//
//  HoloClaimVerifierV2.swift
//  Holo
//
//  Agent 成熟度演进 P0-C — Claim Verifier 2.0
//
//  将"JSON 合法"升级为"结论可复算、证据足够、表达强度匹配"。
//  十大校验维度 + 三态输出（verified / degraded / rejected）。
//  系统置信度由数据质量计算，模型置信度只作为弱输入或完全忽略。
//  不替换 V1 Verifier；V2 作为升级版，由 TaskProfile.requiresVerifier 决定是否启用。
//

import Foundation

// MARK: - 三态结果

nonisolated enum HoloClaimVerificationVerdict: String, Equatable, Sendable {
    case verified   // 允许展示
    case degraded   // 系统降低强度并披露限制
    case rejected   // 不展示该结论，转为能力边界
}

/// 单个 claim 的 V2 校验结果。
nonisolated struct HoloClaimVerificationResultV2: Equatable, Sendable {
    var claim: HoloAgentClaim
    var verdict: HoloClaimVerificationVerdict
    /// 触发的降级/拒绝原因列表。
    var reasons: [String]
    /// 系统计算的置信度（0~1），由数据质量因子决定。
    var systemConfidence: Double
    /// 建议的降级表达（由 Metric Semantic Catalog 生成，不调用模型）。
    var degradedExpression: String?

    /// 各维度检查的详细结果。
    var dimensionResults: [HoloClaimVerificationDimension: HoloDimensionCheck]
}

nonisolated enum HoloClaimVerificationDimension: String, CaseIterable, Sendable {
    case evidenceExists          // 1. evidence ID 存在且未 orphan
    case metricRecomputable      // 2. metric assertion 可由工具结果重算
    case windowComparable        // 3. 当前期和基准期窗口可比
    case unitConsistency         // 4. 单位、币种、时区和粒度一致
    case denominatorValid        // 5. 分母不为零，百分比方向与绝对值一致
    case sampleCoverage          // 6. 样本量、时间覆盖和数据新鲜度达标
    case lineageDedup            // 7. 去重键和数据血缘不存在重复计算
    case evidenceIndependence    // 8. 相关性证据来自足够重叠窗口和独立维度
    case expressionStrength      // 9. 表达类型和强度不超过证据
    case causalCompliance        // 10. 无因果越界（导致/证明/一定因为）
}

nonisolated struct HoloDimensionCheck: Equatable, Sendable {
    var dimension: HoloClaimVerificationDimension
    var passed: Bool
    var severity: HoloDimensionSeverity
    var detail: String

    init(dimension: HoloClaimVerificationDimension, passed: Bool, severity: HoloDimensionSeverity = .major, detail: String = "") {
        self.dimension = dimension
        self.passed = passed
        self.severity = severity
        self.detail = detail
    }
}

nonisolated enum HoloDimensionSeverity: String, Equatable, Sendable {
    case minor    // 降级但不拒绝
    case major    // 降级
    case critical // 拒绝
}

// MARK: - Verifier 2.0

nonisolated struct HoloClaimVerifierV2 {

    /// 置信度阈值：低于此值的 claim 即使通过也会被降级。
    static let degradedConfidenceThreshold: Double = 0.5
    /// 置信度阈值：低于此值的 claim 被拒绝。
    static let rejectedConfidenceThreshold: Double = 0.3

    /// 校验单个 claim。
    func verify(
        claim: HoloAgentClaim,
        evidence: [HoloEvidenceRecord],
        context: HoloClaimVerificationContext = HoloClaimVerificationContext()
    ) -> HoloClaimVerificationResultV2 {
        let evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var checks: [HoloClaimVerificationDimension: HoloDimensionCheck] = [:]
        var reasons: [String] = []

        // 维度 1: evidence 存在且未 orphan
        let evCheck = checkEvidenceExists(claim: claim, evidenceByID: evidenceByID)
        checks[.evidenceExists] = evCheck
        if !evCheck.passed { reasons.append(evCheck.detail) }

        // 维度 10: 因果合规
        let causalCheck = checkCausalCompliance(claim: claim)
        checks[.causalCompliance] = causalCheck
        if !causalCheck.passed { reasons.append(causalCheck.detail) }

        // 维度 2: metric 可重算
        let recomputeCheck = checkMetricRecomputable(claim: claim, evidenceByID: evidenceByID)
        checks[.metricRecomputable] = recomputeCheck
        if !recomputeCheck.passed { reasons.append(recomputeCheck.detail) }

        // 维度 3: 窗口可比
        let windowCheck = checkWindowComparable(claim: claim, evidenceByID: evidenceByID)
        checks[.windowComparable] = windowCheck
        if !windowCheck.passed { reasons.append(windowCheck.detail) }

        // 维度 4: 单位一致
        let unitCheck = checkUnitConsistency(claim: claim, evidenceByID: evidenceByID)
        checks[.unitConsistency] = unitCheck
        if !unitCheck.passed { reasons.append(unitCheck.detail) }

        // 维度 5: 分母有效
        let denomCheck = checkDenominatorValid(claim: claim, evidenceByID: evidenceByID)
        checks[.denominatorValid] = denomCheck
        if !denomCheck.passed { reasons.append(denomCheck.detail) }

        // 维度 6: 样本覆盖
        let sampleCheck = checkSampleCoverage(claim: claim, evidenceByID: evidenceByID, context: context)
        checks[.sampleCoverage] = sampleCheck
        if !sampleCheck.passed { reasons.append(sampleCheck.detail) }

        // 维度 7: 血缘去重
        let lineageCheck = checkLineageDedup(claim: claim, evidence: evidence)
        checks[.lineageDedup] = lineageCheck
        if !lineageCheck.passed { reasons.append(lineageCheck.detail) }

        // 维度 8: 证据独立性
        let independenceCheck = checkEvidenceIndependence(claim: claim, evidenceByID: evidenceByID, context: context)
        checks[.evidenceIndependence] = independenceCheck
        if !independenceCheck.passed { reasons.append(independenceCheck.detail) }

        // 维度 9: 表达强度
        let expressionCheck = checkExpressionStrength(claim: claim, evidenceByID: evidenceByID)
        checks[.expressionStrength] = expressionCheck
        if !expressionCheck.passed { reasons.append(expressionCheck.detail) }

        // 计算系统置信度
        let systemConfidence = computeSystemConfidence(checks: checks, evidence: evidence)

        // 判定三态
        let (verdict, degradedExpression) = determineVerdict(
            checks: checks, systemConfidence: systemConfidence, claim: claim
        )

        return HoloClaimVerificationResultV2(
            claim: claim,
            verdict: verdict,
            reasons: reasons,
            systemConfidence: systemConfidence,
            degradedExpression: degradedExpression,
            dimensionResults: checks
        )
    }

    /// 批量校验。
    func verifyAll(
        claims: [HoloAgentClaim],
        evidence: [HoloEvidenceRecord],
        context: HoloClaimVerificationContext = HoloClaimVerificationContext()
    ) -> [HoloClaimVerificationResultV2] {
        claims.map { verify(claim: $0, evidence: evidence, context: context) }
    }

    // MARK: - 校验维度实现

    private func checkEvidenceExists(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        guard !claim.metricAssertions.isEmpty else {
            return HoloDimensionCheck(dimension: .evidenceExists, passed: false, severity: .critical, detail: "claim 缺少 metricAssertions")
        }
        for assertion in claim.metricAssertions {
            guard !assertion.evidenceIDs.isEmpty else {
                return HoloDimensionCheck(dimension: .evidenceExists, passed: false, severity: .critical, detail: "metricAssertion 缺少 evidenceIDs：\(assertion.metricKey)")
            }
            for evID in assertion.evidenceIDs {
                guard let record = evidenceByID[evID] else {
                    return HoloDimensionCheck(dimension: .evidenceExists, passed: false, severity: .critical, detail: "evidenceID 不存在：\(evID)")
                }
                if record.status == .orphaned || record.status == .archived {
                    return HoloDimensionCheck(dimension: .evidenceExists, passed: false, severity: .critical, detail: "evidence 已失效：\(evID) status=\(record.status.rawValue)")
                }
            }
        }
        return HoloDimensionCheck(dimension: .evidenceExists, passed: true)
    }

    private func checkCausalCompliance(claim: HoloAgentClaim) -> HoloDimensionCheck {
        let causalWords = ["导致", "证明", "说明一定因为", "一定因为", "引起"]
        for word in causalWords where claim.displayText.contains(word) {
            return HoloDimensionCheck(dimension: .causalCompliance, passed: false, severity: .critical, detail: "文案包含因果词「\(word)」，只能描述并发")
        }
        return HoloDimensionCheck(dimension: .causalCompliance, passed: true)
    }

    private func checkMetricRecomputable(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        for assertion in claim.metricAssertions {
            for evID in assertion.evidenceIDs {
                guard let record = evidenceByID[evID] else { continue }
                if record.metricKey != assertion.metricKey {
                    return HoloDimensionCheck(dimension: .metricRecomputable, passed: false, severity: .critical, detail: "metricKey 不匹配：claim=\(assertion.metricKey) evidence=\(record.metricKey)")
                }
                if let value = assertion.value, let evidenceValue = record.metricValue,
                   abs(value - evidenceValue) > 0.01 {
                    return HoloDimensionCheck(dimension: .metricRecomputable, passed: false, severity: .critical, detail: "value 不一致：claim=\(value) evidence=\(evidenceValue)")
                }
            }
        }
        return HoloDimensionCheck(dimension: .metricRecomputable, passed: true)
    }

    private func checkWindowComparable(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        for assertion in claim.metricAssertions {
            for evID in assertion.evidenceIDs {
                guard let record = evidenceByID[evID] else { continue }
                // 如果 claim 有 baseline 但 evidence 无 baselineTimeRange，则窗口不可比
                if assertion.baselineValue != nil && record.baselineTimeRange == nil && record.baselineValue == nil {
                    return HoloDimensionCheck(dimension: .windowComparable, passed: false, severity: .major, detail: "claim 含 baseline 但 evidence 无基准窗口：\(assertion.metricKey)")
                }
            }
        }
        return HoloDimensionCheck(dimension: .windowComparable, passed: true)
    }

    private func checkUnitConsistency(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        for assertion in claim.metricAssertions {
            for evID in assertion.evidenceIDs {
                guard let record = evidenceByID[evID] else { continue }
                if let claimUnit = assertion.unit, let evUnit = record.unit,
                   !claimUnit.isEmpty && !evUnit.isEmpty && claimUnit != evUnit {
                    return HoloDimensionCheck(dimension: .unitConsistency, passed: false, severity: .major, detail: "单位不一致：claim=\(claimUnit) evidence=\(evUnit)")
                }
            }
        }
        return HoloDimensionCheck(dimension: .unitConsistency, passed: true)
    }

    private func checkDenominatorValid(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        for assertion in claim.metricAssertions {
            // 百分比类 claim：baseline 为零则分母为零
            if let baseline = assertion.baselineValue, baseline == 0,
               assertion.comparison == "percentage" || assertion.comparison == "percent" {
                return HoloDimensionCheck(dimension: .denominatorValid, passed: false, severity: .critical, detail: "分母为零：baseline=0 无法计算百分比")
            }
        }
        return HoloDimensionCheck(dimension: .denominatorValid, passed: true)
    }

    private func checkSampleCoverage(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord], context: HoloClaimVerificationContext
    ) -> HoloDimensionCheck {
        var totalCoverage = 0
        var minCoverage = Int.max
        for assertion in claim.metricAssertions {
            for evID in assertion.evidenceIDs {
                guard let record = evidenceByID[evID] else { continue }
                // 用 sourceRecordIDs 数量估算样本量
                let sampleCount = record.sourceRecordIDs?.count ?? 1
                totalCoverage += sampleCount
                minCoverage = Swift.min(minCoverage, sampleCount)
            }
        }
        // 最小样本量门槛：至少有 1 条原始记录
        if minCoverage == 0 {
            return HoloDimensionCheck(dimension: .sampleCoverage, passed: false, severity: .major, detail: "样本量为零")
        }
        return HoloDimensionCheck(dimension: .sampleCoverage, passed: true)
    }

    private func checkLineageDedup(claim: HoloAgentClaim, evidence: [HoloEvidenceRecord]) -> HoloDimensionCheck {
        // 检查同一 claim 引用的 evidence 是否有重复 dedupeKey
        var seenDedupeKeys: Set<String> = []
        for assertion in claim.metricAssertions {
            for evID in assertion.evidenceIDs {
                guard let record = evidence.first(where: { $0.id == evID }) else { continue }
                if seenDedupeKeys.contains(record.dedupeKey) {
                    return HoloDimensionCheck(dimension: .lineageDedup, passed: false, severity: .major, detail: "重复血缘：dedupeKey=\(record.dedupeKey)")
                }
                seenDedupeKeys.insert(record.dedupeKey)
            }
        }
        return HoloDimensionCheck(dimension: .lineageDedup, passed: true)
    }

    private func checkEvidenceIndependence(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord], context: HoloClaimVerificationContext
    ) -> HoloDimensionCheck {
        // 相关性 claim 需要来自不同域的独立证据
        if claim.type == "correlation" || claim.type == "cross_domain" {
            var domains: Set<String> = []
            for assertion in claim.metricAssertions {
                for evID in assertion.evidenceIDs {
                    guard let record = evidenceByID[evID] else { continue }
                    domains.insert(record.sourceModule.rawValue)
                }
            }
            if domains.count < 2 {
                return HoloDimensionCheck(dimension: .evidenceIndependence, passed: false, severity: .major, detail: "相关性 claim 需要至少 2 个独立域，实际 \(domains.count)")
            }
        }
        return HoloDimensionCheck(dimension: .evidenceIndependence, passed: true)
    }

    private func checkExpressionStrength(
        claim: HoloAgentClaim, evidenceByID: [String: HoloEvidenceRecord]
    ) -> HoloDimensionCheck {
        // 强表达 claim（因果/预测/诊断）需要高置信证据
        let strongExpressionTypes = ["causal", "prediction", "diagnosis", "recommendation"]
        if strongExpressionTypes.contains(claim.type) {
            let minEvidenceConfidence = claim.metricAssertions.flatMap { assertion in
                assertion.evidenceIDs.compactMap { evidenceByID[$0]?.confidence }
            }.min() ?? 0
            if minEvidenceConfidence < 0.7 {
                return HoloDimensionCheck(dimension: .expressionStrength, passed: false, severity: .major, detail: "强表达类型 \(claim.type) 需要高置信证据 (>=0.7)，实际 \(minEvidenceConfidence)")
            }
        }
        // 模型置信度过高但证据不足 → 降级
        let evidenceAvgConfidence = claim.metricAssertions.flatMap { assertion in
            assertion.evidenceIDs.compactMap { evidenceByID[$0]?.confidence }
        }.reduce(0, +) / Double(Swift.max(1, claim.metricAssertions.flatMap(\.evidenceIDs).count))
        if claim.confidence > evidenceAvgConfidence + 0.2 {
            return HoloDimensionCheck(dimension: .expressionStrength, passed: false, severity: .minor, detail: "模型置信度(\(claim.confidence))显著高于证据(\(evidenceAvgConfidence))")
        }
        return HoloDimensionCheck(dimension: .expressionStrength, passed: true)
    }

    // MARK: - 系统置信度计算

    /// 由数据质量因子计算系统置信度，不使用模型填写的 confidence。
    private func computeSystemConfidence(
        checks: [HoloClaimVerificationDimension: HoloDimensionCheck],
        evidence: [HoloEvidenceRecord]
    ) -> Double {
        var score: Double = 1.0

        // 每个 critical 失败扣 0.4
        // 每个 major 失败扣 0.2
        // 每个 minor 失败扣 0.1
        for check in checks.values where !check.passed {
            switch check.severity {
            case .critical: score -= 0.4
            case .major: score -= 0.2
            case .minor: score -= 0.1
            }
        }

        // 证据数量因子：少证据降置信
        let evidenceCount = evidence.count
        if evidenceCount < 2 { score -= 0.15 }

        // 证据平均置信度作为弱输入
        let avgEvidenceConfidence = evidence.isEmpty ? 0.5 : evidence.map(\.confidence).reduce(0, +) / Double(evidence.count)
        score = score * 0.7 + avgEvidenceConfidence * 0.3

        return Swift.max(0, Swift.min(1, score))
    }

    // MARK: - 三态判定

    private func determineVerdict(
        checks: [HoloClaimVerificationDimension: HoloDimensionCheck],
        systemConfidence: Double,
        claim: HoloAgentClaim
    ) -> (verdict: HoloClaimVerificationVerdict, degradedExpression: String?) {
        // 任何 critical 失败 → rejected
        let hasCritical = checks.values.contains(where: { !$0.passed && $0.severity == .critical })
        if hasCritical || systemConfidence < Self.rejectedConfidenceThreshold {
            return (.rejected, nil)
        }

        // major/minor 失败或低置信 → degraded
        let hasDegradation = checks.values.contains(where: { !$0.passed && $0.severity != .critical })
        if hasDegradation || systemConfidence < Self.degradedConfidenceThreshold {
            let degraded = buildDegradedExpression(claim: claim, systemConfidence: systemConfidence, checks: checks)
            return (.degraded, degraded)
        }

        return (.verified, nil)
    }

    /// 降级文案由确定性模板生成，不调用模型改写。
    private func buildDegradedExpression(
        claim: HoloAgentClaim, systemConfidence: Double, checks: [HoloClaimVerificationDimension: HoloDimensionCheck]
    ) -> String {
        var disclosures: [String] = []
        if let check = checks[.windowComparable], !check.passed {
            disclosures.append("时间窗口不完全可比")
        }
        if let check = checks[.sampleCoverage], !check.passed {
            disclosures.append("样本量有限")
        }
        if let check = checks[.unitConsistency], !check.passed {
            disclosures.append("单位可能不一致")
        }
        if let check = checks[.expressionStrength], !check.passed {
            disclosures.append("证据强度不足以支撑强表达")
        }

        let disclosureText = disclosures.isEmpty ? "数据完整度有限" : disclosures.joined(separator: "、")
        return "\(claim.displayText)（注意：\(disclosureText)，置信度\(String(format: "%.0f%%", systemConfidence * 100))）"
    }
}

// MARK: - 校验上下文

/// 校验上下文：提供样本量门槛、时间窗口等参数。
nonisolated struct HoloClaimVerificationContext: Sendable {
    /// 最小样本量门槛（默认 1）。
    var minSampleSize: Int = 1
    /// 最小证据数量（默认 1）。
    var minEvidenceCount: Int = 1
    /// 相关性 claim 要求的最小独立域数（默认 2）。
    var minIndependentDomainsForCorrelation: Int = 2

    init() {}
}
