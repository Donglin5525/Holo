//
//  HoloAnswerCoverageVerifier.swift
//  Holo
//
//  HoloAI Agent 统一结果语义契约 P2 — 展示前验证与自动恢复判定
//  在 Claim Verifier 之后、交付之前拦截：内部 token / 覆盖未披露 / 方向矛盾 /
//  编造分组 / 无证据数字结论。原因只用短码，不记录用户原文。
//

import Foundation

/// 验证结论三态：pass 原样交付；recoverable 可本地修复；failed 只能给边界说明。
nonisolated enum HoloAnswerCoverageVerdict: Equatable, Sendable {
    case pass
    case recoverable([String])
    case failed([String])
}

nonisolated enum HoloAnswerCoverageVerifier {

    // MARK: 原因码（不记录用户原文）

    static let codeInternalToken = "INTERNAL_TOKEN"
    static let codeCoverageUndisclosed = "COVERAGE_UNDISCLOSED"
    static let codeDirectionConflict = "DIRECTION_CONFLICT"
    static let codeUnknownGroup = "UNKNOWN_GROUP"
    static let codeNoEvidence = "NO_EVIDENCE"

    // MARK: 验证入口

    static func verify(
        result: HoloRenderedAgentResult,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage?
    ) -> HoloAnswerCoverageVerdict {
        var recoverableCodes: [String] = []
        var failedCodes: [String] = []
        let texts = userFacingTexts(of: result)
        let knownLabels = Set(evidence.compactMap { $0.semantic?.groupLabel })

        // 内部标识 / 公式 / 占位文本
        if texts.contains(where: { containsInternalToken($0) }) {
            recoverableCodes.append(codeInternalToken)
        }

        // 覆盖不足必须披露
        if let coverage {
            let ratio = coverage.coverageRatio
                ?? (coverage.totalDays > 0 ? Double(coverage.coveredDays) / Double(coverage.totalDays) : 1)
            if ratio < 0.9, !coverageDisclosed(result.coverageText) {
                recoverableCodes.append(codeCoverageUndisclosed)
            }
        }

        // 方向矛盾与编造分组只在有语义证据可核对时检查（旧证据跳过，走兼容兜底）
        if !knownLabels.isEmpty {
            if texts.contains(where: { hasDirectionConflict($0, knownLabels: knownLabels) }) {
                recoverableCodes.append(codeDirectionConflict)
            }
            if texts.contains(where: { !unknownGroupMentions(in: $0, knownLabels: knownLabels).isEmpty }) {
                recoverableCodes.append(codeUnknownGroup)
            }
        }

        // 连证据都没有却给出数字结论
        if evidence.isEmpty, texts.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
            failedCodes.append(codeNoEvidence)
        }

        if !failedCodes.isEmpty { return .failed(failedCodes) }
        if !recoverableCodes.isEmpty { return .recoverable(recoverableCodes) }
        return .pass
    }

    // MARK: 用户可见文本收集

    static func userFacingTexts(of result: HoloRenderedAgentResult) -> [String] {
        var texts = [result.title, result.summary]
        texts += [result.headline, result.directAnswer, result.coverageText].compactMap { $0 }
        texts += result.limitations ?? []
        texts += result.sections.flatMap { [$0.title, $0.body] }
        texts += result.evidenceReferences.map(\.summary)
        return texts
    }

    // MARK: 内部 token

    /// 目录规则之外再补半角公式调用（如 `difference(`），全角括号的中文文案不受影响。
    static func containsInternalToken(_ text: String) -> Bool {
        if HoloMetricSemanticCatalog.containsInternalToken(text) { return true }
        return text.range(of: #"[A-Za-z_]{2,}\("#, options: .regularExpression) != nil
    }

    // MARK: 覆盖披露

    static func coverageDisclosed(_ coverageText: String?) -> Bool {
        guard let text = coverageText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return false
        }
        return text.contains("/") || text.contains("覆盖")
    }

    // MARK: 方向矛盾

    /// 同一句内、同一分组标签在不同分句中被赋予相反方向（增加 vs 减少）视为矛盾。
    static func hasDirectionConflict(_ text: String, knownLabels: Set<String>) -> Bool {
        guard !knownLabels.isEmpty else { return false }
        let increaseWords = ["增加", "上涨", "上升", "回升"]
        let decreaseWords = ["减少", "下降", "降低", "回落"]
        let sentences = text.split { "。!！?？\n".contains($0) }
        for sentence in sentences {
            let clauses = sentence.split { "，,；;、".contains($0) }
            var directionByLabel: [String: HoloMetricDirection] = [:]
            for clause in clauses {
                let clauseText = String(clause)
                let direction: HoloMetricDirection?
                if increaseWords.contains(where: { clauseText.contains($0) }) {
                    direction = .increase
                } else if decreaseWords.contains(where: { clauseText.contains($0) }) {
                    direction = .decrease
                } else {
                    direction = nil
                }
                guard let direction else { continue }
                for label in knownLabels where clauseText.contains(label) {
                    if let existing = directionByLabel[label], existing != direction { return true }
                    directionByLabel[label] = direction
                }
            }
        }
        return false
    }

    // MARK: 编造分组

    /// 抽取「名称（+数字」模式里的名称；名称后缀不在 evidence 语义分组中即视为编造。
    /// 只负责发现，具体名称不外抛（日志不记录用户原文）。
    static func unknownGroupMentions(in text: String, knownLabels: Set<String>) -> [String] {
        guard !knownLabels.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"([\p{Han}A-Za-z]{1,12})（[+-]"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        var unknown: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            // 名称前可能粘连动词（如「多在餐饮」），任一已知标签是其后缀即视为已核对。
            let matched = knownLabels.contains { name == $0 || name.hasSuffix($0) }
            if !matched { unknown.append(name) }
        }
        return unknown
    }
}
