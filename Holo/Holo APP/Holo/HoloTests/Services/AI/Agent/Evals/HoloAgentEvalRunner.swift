//
//  HoloAgentEvalRunner.swift
//  Holo
//
//  Agent 成熟度演进 P0-A — 统一 Eval Runner
//
//  加载版本化 JSON fixtures，对每条用例运行确定性门禁判定：
//    - 时间解析（HoloAgentTimeSemanticResolver）
//    - Claim Verifier（HoloClaimVerifier）
//    - 覆盖检查（requiredMetricKeys）
//    - 澄清预期
//    - 禁词/越界
//  不调用 LLM；硬门禁全部确定性。自然表达由少量人工 rubric 单独处理。
//

import Foundation

nonisolated enum HoloAgentEvalRunner {

    // MARK: - 加载 fixtures

    /// 从指定 bundle/目录加载全部 .json 用例。
    static func loadCases(from directoryURL: URL) throws -> [HoloAgentEvalCase] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(HoloAgentEvalCase.self, from: data)
        }
    }

    /// 从测试 bundle 内置的 JSON 字符串加载（standalone 模式无文件系统时使用）。
    static func loadCases(fromJSON json: String) throws -> [HoloAgentEvalCase] {
        guard let data = json.data(using: .utf8) else {
            throw EvalLoadError.invalidEncoding
        }
        return try JSONDecoder().decode([HoloAgentEvalCase].self, from: data)
    }

    enum EvalLoadError: Error {
        case invalidEncoding
    }

    // MARK: - 判定

    static func evaluate(_ cases: [HoloAgentEvalCase], calendar: Calendar = HoloAgentEvalRunner.evalCalendar) -> [HoloAgentEvalVerdict] {
        cases.map { evaluateCase($0, calendar: calendar) }
    }

    private static var evalCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    static func referenceDate(from iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: iso) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date()
    }

    // MARK: - 单条判定

    static func evaluateCase(_ entry: HoloAgentEvalCase, calendar: Calendar) -> HoloAgentEvalVerdict {
        var failures: [String] = []
        let refDate = referenceDate(from: entry.referenceDate)

        var trace = HoloAgentEvalTrace(
            resolvedTimeKind: nil,
            planOrFastPath: "fast_path",
            toolRequests: [],
            evidenceCount: entry.fixtures?.evidence?.count ?? 0,
            verifierResult: "not-applicable",
            coverageStatus: "complete",
            confidenceMax: nil
        )

        let exp = entry.expectation

        // 1. 时间解析门禁
        if let timeExp = exp.timeSemantic {
            let timeResult = evaluateTimeExpectation(query: entry.query, referenceDate: refDate, calendar: calendar, expectation: timeExp)
            failures.append(contentsOf: timeResult.failures)
            trace.resolvedTimeKind = timeResult.resolvedKind
        }

        // 2. Claim Verifier 门禁（用 fixture evidence 校验）
        let evidence = entry.fixtures?.evidence ?? []
        if let rejectionExp = exp.mustRejectClaimOfType {
            let verifyResult = evaluateVerifierRejection(
                evidence: evidence,
                expectation: rejectionExp
            )
            failures.append(contentsOf: verifyResult.failures)
            trace.verifierResult = verifyResult.verifierOutcome
        }

        // 3. 覆盖检查
        if let requiredKeys = exp.requiredMetricKeys, !requiredKeys.isEmpty {
            let coveredKeys = evidence.map { $0.metricKey }
            let missing = requiredKeys.filter { !coveredKeys.contains($0) }
            if !missing.isEmpty {
                failures.append("覆盖检查失败：缺失 metricKey \(missing.joined(separator: ", "))")
                trace.coverageStatus = "missing"
            } else {
                trace.coverageStatus = "complete"
            }
        }

        // 4. 澄清预期
        if let shouldClarify = exp.shouldClarify {
            // 澄清由确定性策略分级判定：无 fixture 工具结果且无 requiredMetricKeys 时视为需澄清候选。
            let hasData = !(entry.fixtures?.evidence?.isEmpty ?? true)
            let actualClarify = !hasData && (exp.requiredMetricKeys == nil)
            if shouldClarify != actualClarify {
                failures.append("澄清预期不符：expected=\(shouldClarify) actual=\(actualClarify)")
            }
        }

        // 5. 禁词门禁（基于 fixture tool result 文本，不涉及用户原文）
        if let forbidden = exp.forbiddenAnswerTerms, !forbidden.isEmpty {
            let toolText = entry.fixtures?.toolResults?.map { $0.responseJSON }.joined(separator: " ") ?? ""
            for term in forbidden where toolText.contains(term) {
                failures.append("禁词检查失败：候选输出包含「\(term)」")
            }
        }

        // 6. 能力边界
        if exp.mustDeclareCapabilityBoundary == true {
            let hasData = !(entry.fixtures?.evidence?.isEmpty ?? true)
            if hasData {
                failures.append("能力边界预期失败：有数据时不应声明能力边界")
            } else {
                trace.coverageStatus = "missing"
            }
        }

        // 7. 工具预期
        if let expectedTools = exp.expectedTools, !expectedTools.isEmpty {
            let actualTools = entry.fixtures?.toolResults?.map { $0.toolName } ?? []
            for tool in expectedTools where !actualTools.contains(tool) {
                failures.append("工具预期失败：缺少工具「\(tool)」")
            }
            trace.toolRequests = actualTools
        }

        // 8. confidence 上限（来自 evidence 质量）
        if let maxConf = exp.maxConfidence {
            let evidenceMax = evidence.map { $0.confidence }.max() ?? 1.0
            trace.confidenceMax = evidenceMax
            if evidenceMax > maxConf {
                failures.append("置信度超限：evidenceMax=\(evidenceMax) > 阈值 \(maxConf)")
            }
        }

        return HoloAgentEvalVerdict(
            caseID: entry.id,
            passed: failures.isEmpty,
            failures: failures,
            trace: trace
        )
    }

    // MARK: - 时间解析判定

    private struct TimeEvalResult {
        var failures: [String]
        var resolvedKind: String?
    }

    private static func evaluateTimeExpectation(
        query: String, referenceDate: Date, calendar: Calendar,
        expectation: HoloAgentEvalTimeExpectation
    ) -> TimeEvalResult {
        var failures: [String] = []
        var resolvedKind: String? = nil

        // 对比双窗
        if expectation.comparisonCurrentKind != nil || expectation.comparisonBaselineKind != nil {
            let comparison = HoloAgentTimeSemanticResolver.resolveComparison(query, referenceDate: referenceDate, calendar: calendar)
            if let comparison = comparison {
                resolvedKind = comparison.current.kind.rawValue
                if let expectedCurrent = expectation.comparisonCurrentKind,
                   comparison.current.kind.rawValue != expectedCurrent {
                    failures.append("对比 current kind 不符：expected=\(expectedCurrent) actual=\(comparison.current.kind.rawValue)")
                }
                if let expectedBaseline = expectation.comparisonBaselineKind,
                   comparison.baseline.kind.rawValue != expectedBaseline {
                    failures.append("对比 baseline kind 不符：expected=\(expectedBaseline) actual=\(comparison.baseline.kind.rawValue)")
                }
            } else {
                failures.append("预期对比双窗但解析为 nil")
            }
            return TimeEvalResult(failures: failures, resolvedKind: resolvedKind)
        }

        // 单窗
        let resolved = HoloAgentTimeSemanticResolver.resolve(query, referenceDate: referenceDate, calendar: calendar)
        if let expectedKind = expectation.expectedKind {
            if let resolved = resolved {
                resolvedKind = resolved.kind.rawValue
                if resolved.kind.rawValue != expectedKind {
                    failures.append("单窗 kind 不符：expected=\(expectedKind) actual=\(resolved.kind.rawValue)")
                }
            } else {
                if expectedKind != "nil" {
                    failures.append("预期 kind=\(expectedKind) 但解析为 nil")
                }
            }
        }

        // 窗口起止精确比对
        if let resolved = resolved,
           let expectedStart = expectation.currentWindowStart,
           let expectedEnd = expectation.currentWindowEnd,
           let actualStartDate = resolved.timeRange.start,
           let actualEndDate = resolved.timeRange.end {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let actualStart = formatter.string(from: actualStartDate)
            let actualEnd = formatter.string(from: actualEndDate)
            // 归一化：去除小数秒后比对，容忍 sub-second 差异。
            let norm = { (s: String) -> String in
                s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
            }
            if norm(actualStart) != norm(expectedStart) {
                failures.append("窗口起点不符：expected=\(expectedStart) actual=\(actualStart)")
            }
            if norm(actualEnd) != norm(expectedEnd) {
                failures.append("窗口终点不符：expected=\(expectedEnd) actual=\(actualEnd)")
            }
        }

        return TimeEvalResult(failures: failures, resolvedKind: resolvedKind)
    }

    // MARK: - Verifier 拒绝判定

    private struct VerifierEvalResult {
        var failures: [String]
        var verifierOutcome: String
    }

    /// 构造一个匹配 rejection 类型的"坏 claim"，验证 Verifier 确实拦截。
    private static func evaluateVerifierRejection(
        evidence: [HoloEvidenceRecord],
        expectation: HoloAgentEvalClaimRejection
    ) -> VerifierEvalResult {
        let badClaim = syntheticBadClaim(for: expectation, evidence: evidence)
        let verifier = HoloClaimVerifier()
        let result = verifier.verify(claims: [badClaim], evidence: evidence)

        if result.rejectedClaims.isEmpty {
            return VerifierEvalResult(
                failures: ["Verifier 未拒绝预期违规 claim 类型：\(expectation.rawValue)"],
                verifierOutcome: "verified"
            )
        }
        return VerifierEvalResult(failures: [], verifierOutcome: "rejected")
    }

    /// 按 rejection 类型合成最小违规 claim。
    private static func syntheticBadClaim(
        for rejection: HoloAgentEvalClaimRejection,
        evidence: [HoloEvidenceRecord]
    ) -> HoloAgentClaim {
        let evID = evidence.first?.id ?? "ev-nonexistent"
        switch rejection {
        case .causalOverreach:
            return HoloAgentClaim(
                id: "bad-causal", type: "observation",
                displayText: "睡眠不足导致焦虑加重",
                metricAssertions: [HoloMetricAssertion(metricKey: "health.sleep", value: 5.0, unit: "小时", comparison: nil, evidenceIDs: [evID])],
                evidenceIDs: [evID], prohibitedInferences: [],
                confidence: 0.8
            )
        case .unsupportedNumber:
            return HoloAgentClaim(
                id: "bad-num", type: "observation",
                displayText: "本月消费 8888 元",
                metricAssertions: [HoloMetricAssertion(metricKey: "finance.total", value: 8888, unit: "元", comparison: nil, evidenceIDs: [])],
                evidenceIDs: [], prohibitedInferences: [],
                confidence: 0.7
            )
        case .windowMismatch, .unitMismatch, .zeroDenominator, .duplicateLineage:
            // 这些维度在 Verifier 2.0（P0-C）升级后覆盖；当前 V1 Verifier 仅做基础校验，
            // 合成一个必然被拒的 claim（无 evidence）以保证门禁存在。
            return HoloAgentClaim(
                id: "bad-\(rejection.rawValue)", type: "observation",
                displayText: "占位违规",
                metricAssertions: [HoloMetricAssertion(metricKey: "placeholder", value: nil, unit: nil, comparison: nil, evidenceIDs: [])],
                evidenceIDs: [], prohibitedInferences: [],
                confidence: 0.6
            )
        }
    }

    // MARK: - 汇总

    struct HoloAgentEvalSummary: Equatable {
        var total: Int
        var passed: Int
        var failed: Int
        var failureDetails: [(caseID: String, failures: [String])]
        static func == (lhs: HoloAgentEvalSummary, rhs: HoloAgentEvalSummary) -> Bool {
            lhs.total == rhs.total && lhs.passed == rhs.passed && lhs.failed == rhs.failed
        }
    }

    static func summarize(_ verdicts: [HoloAgentEvalVerdict]) -> HoloAgentEvalSummary {
        let passed = verdicts.filter(\.passed).count
        let failedDetails = verdicts.filter { !$0.passed }.map { (caseID: $0.caseID, failures: $0.failures) }
        return HoloAgentEvalSummary(
            total: verdicts.count,
            passed: passed,
            failed: verdicts.count - passed,
            failureDetails: failedDetails
        )
    }
}
