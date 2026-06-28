//
//  HealthInsightFallbackBuilder.swift
//  Holo
//
//  健康洞察本地兜底（审查修订 P13：fallback 文案统一在此管理）。
//  - 数据不足：诚实空态，不伪装跨模块洞察。
//  - 后端失败 / core 校验失败：本地规则文案作为 core，lifestyleLoops 始终为空（不展示伪跨模块）。
//  方案 5.3：「无缓存且失败：展示本地规则洞察，不展示伪跨模块生活闭环」。
//

import Foundation

struct HealthInsightFallbackBuilder {

    /// 数据积累期诚实文案。
    static let accumulatingSummary = "健康数据正在积累。连续记录后，HOLO 会尝试把身体状态和任务、习惯、消费、想法串起来。"

    /// 数据不足快照：无 core、无 loops、无 evidence。
    func buildInsufficientData(period: HealthInsightPeriod, now: Date) -> GeneratedHealthInsightSnapshot {
        GeneratedHealthInsightSnapshot(
            generatedAt: now,
            period: period,
            status: .insufficientData,
            coreInsight: nil,
            lifestyleLoops: [],
            evidence: [],
            fallbackReason: "健康数据不足，无法生成洞察"
        )
    }

    /// 后端失败快照：本地规则 core，无生活闭环（不伪装跨模块）。
    func buildFallback(period: HealthInsightPeriod, reason: String?, now: Date) -> GeneratedHealthInsightSnapshot {
        GeneratedHealthInsightSnapshot(
            generatedAt: now,
            period: period,
            status: .fallback,
            coreInsight: buildFallbackCore(now: now),
            lifestyleLoops: [],
            evidence: [],
            fallbackReason: reason
        )
    }

    /// 本地规则 core（LLM core 校验失败时复用）。
    func buildFallbackCore(now: Date) -> GeneratedHealthInsight {
        GeneratedHealthInsight(
            id: "fallback-core-\(HealthInsightContextBuilder.dayKey(from: now))",
            kind: .core,
            domain: .mixed,
            title: "今日核心洞察",
            summary: Self.accumulatingSummary,
            suggestedAction: nil,
            confidence: 0.3,
            evidenceIds: [],
            caveat: "使用本地兜底文案"
        )
    }
}
