//
//  HealthInsightVerifier.swift
//  Holo
//
//  健康洞察质量门禁。
//  Parser 已做 evidenceId 同源过滤 + 基本有效性；Verifier 在此之上做质量校验：
//  - 核心洞察 evidenceIds ≥1 命中真实证据
//  - 生活闭环 evidenceIds ≥2 命中，且对应 evidence 的 domain 去重 ≥2（跨域，审查修订 P5）
//  - confidence 范围 + lifestyleLoop < 0.45 丢弃
//  - title ≤24 字、summary ≤90 字
//  - 医疗/强因果/人格判断禁词
//  不合格的单条 loop 丢弃；core 不合格返回 nil（由 Service 走 fallback core）。
//

import Foundation

struct HealthInsightVerifier {

    private let maxTitleLength = 24
    private let maxSummaryLength = 90
    /// loop 最低置信度。从 0.55 下调到 0.45：ContextBuilder 候选 confidenceHint 上界在 lift=1.5 时恰为 0.55，
    /// 原阈值与候选上界临界，LLM 略低于 0.55 即全弃，导致生活闭环系统性为空（记忆 12743）。
    private let minLoopConfidence = 0.45

    /// 医疗诊断 / 强因果 / 人格判断禁词。命中任一则该条洞察被丢弃。
    private let bannedTerms = [
        "诊断", "确诊", "抑郁症", "焦虑症", "疾病", "生病了", "需要治疗",
        "导致", "证明了", "证明", "说明一定", "就是因为", "是因为你",
        "你很焦虑", "你压力很大", "你抑郁了"
    ]

    func verify(_ parsed: HealthInsightParsedInsights, evidence: [HealthInsightEvidence]) -> HealthInsightParsedInsights {
        let domainById = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0.domain) })

        let core = parsed.coreInsight.flatMap { verifyCore($0, domainById: domainById) }
        let loops = parsed.lifestyleLoops.compactMap { verifyLoop($0, domainById: domainById) }

        return HealthInsightParsedInsights(coreInsight: core, lifestyleLoops: loops)
    }

    // MARK: - 校验规则

    private func verifyCore(_ insight: GeneratedHealthInsight, domainById: [String: HealthInsightDomain]) -> GeneratedHealthInsight? {
        let validIds = insight.evidenceIds.filter { domainById[$0] != nil }
        guard validIds.count >= 1 else { return nil }
        guard passesLengthAndSafety(insight) else { return nil }
        return insight
    }

    private func verifyLoop(_ insight: GeneratedHealthInsight, domainById: [String: HealthInsightDomain]) -> GeneratedHealthInsight? {
        guard insight.confidence >= minLoopConfidence else { return nil }
        let validIds = insight.evidenceIds.filter { domainById[$0] != nil }
        guard validIds.count >= 2 else { return nil }
        // 跨域：命中的 evidenceIds 对应 domain 去重 ≥2（审查修订 P5：判定 evidence.domain，非 loop.domain）
        let domains = Set(validIds.compactMap { domainById[$0] })
        guard domains.count >= 2 else { return nil }
        guard passesLengthAndSafety(insight) else { return nil }
        return insight
    }

    private func passesLengthAndSafety(_ insight: GeneratedHealthInsight) -> Bool {
        guard insight.title.count <= maxTitleLength else { return false }
        guard insight.summary.count <= maxSummaryLength else { return false }
        let combined = insight.title + insight.summary + (insight.caveat ?? "")
        return !bannedTerms.contains { combined.contains($0) }
    }
}
