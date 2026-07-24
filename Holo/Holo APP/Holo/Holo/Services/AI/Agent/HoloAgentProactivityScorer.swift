//
//  HoloAgentProactivityScorer.swift
//  Holo
//
//  Agent 成熟度演进 P2 — 主动评分模型
//
//  在现有 Observer、Expression Decision 和 Action Candidate 上形成低打扰闭环。
//  统一评分：value × confidence × actionability × novelty × timingFitness
//            − interruptionCost − repetitionPenalty
//  结果分四档：notify / store / watch / ignore
//  默认"存储优先、打扰谨慎"。
//

import Foundation

// MARK: - 主动评分输入

/// 主动信号评分所需的全部维度。
nonisolated struct HoloProactivitySignal: Equatable, Sendable {
    /// 价值（0~1）：对用户的潜在价值。
    var value: Double
    /// 置信（0~1）：证据强度。
    var confidence: Double
    /// 可行动性（0~1）：是否可转化为具体动作。
    var actionability: Double
    /// 新颖度（0~1）：是否为用户未知的新信息。
    var novelty: Double
    /// 时宜性（0~1）：当下是否是合适的提醒时机。
    var timingFitness: Double
    /// 打扰成本（0~1）：打断用户注意力的代价。
    var interruptionCost: Double
    /// 重复惩罚（0~1）：近期是否已提醒过类似内容。
    var repetitionPenalty: Double
    /// 用户是否已授权此类通知。
    var userAuthorized: Bool
    /// 来源 claim ID。
    var sourceClaimID: String?
    /// 相关数据域。
    var domain: String?

    init(
        value: Double, confidence: Double, actionability: Double, novelty: Double,
        timingFitness: Double, interruptionCost: Double, repetitionPenalty: Double,
        userAuthorized: Bool, sourceClaimID: String? = nil, domain: String? = nil
    ) {
        self.value = Self.clamp(value)
        self.confidence = Self.clamp(confidence)
        self.actionability = Self.clamp(actionability)
        self.novelty = Self.clamp(novelty)
        self.timingFitness = Self.clamp(timingFitness)
        self.interruptionCost = Self.clamp(interruptionCost)
        self.repetitionPenalty = Self.clamp(repetitionPenalty)
        self.userAuthorized = userAuthorized
        self.sourceClaimID = sourceClaimID
        self.domain = domain
    }

    private static func clamp(_ v: Double) -> Double {
        Swift.max(0, Swift.min(1, v))
    }
}

// MARK: - 评分结果

/// 主动评分结果。
nonisolated struct HoloProactivityScore: Equatable, Sendable {
    /// 最终评分（0~100）。
    var score: Double
    /// 分档结果。
    var tier: HoloProactivityTier
    /// 评分明细（各维度贡献）。
    var breakdown: HoloProactivityBreakdown
    /// 是否允许打扰（只有 notify 档才打扰）。
    var shouldNotify: Bool { tier == .notify }
    /// 是否进入记忆/长廊。
    var shouldStore: Bool { tier == .notify || tier == .store }
}

nonisolated enum HoloProactivityTier: String, Equatable, Sendable {
    case notify  // 高价值、高置信、可行动且已获相应授权
    case store   // 有价值但不值得打扰，进入记忆/长廊
    case watch   // 证据不足，继续观察
    case ignore  // 低价值或重复
}

nonisolated struct HoloProactivityBreakdown: Equatable, Sendable {
    var positiveComponent: Double  // 正向贡献
    var negativeComponent: Double  // 负向扣减
    var valueContribution: Double
    var confidenceContribution: Double
    var actionabilityContribution: Double
    var noveltyContribution: Double
    var timingContribution: Double
    var interruptionDeduction: Double
    var repetitionDeduction: Double
}

// MARK: - 评分器

nonisolated enum HoloAgentProactivityScorer {

    /// 评分阈值。
    struct Thresholds {
        var notifyThreshold: Double = 60   // >= 65 才 notify
        var storeThreshold: Double = 30    // >= 35 才 store
        var watchThreshold: Double = 12    // >= 15 才 watch
    }

    static let defaultThresholds = Thresholds()

    /// 计算主动信号评分。
    static func score(
        _ signal: HoloProactivitySignal,
        thresholds: Thresholds = defaultThresholds
    ) -> HoloProactivityScore {
        // 正向：加权几何平均（5 项乘积开 5 次方），保证全维度满足但不急剧衰减
        let product = signal.value * signal.confidence * signal.actionability
            * signal.novelty * signal.timingFitness
        let positive = pow(product, 1.0 / 5.0)

        // 负向：interruptionCost + repetitionPenalty（加权）
        let negative = signal.interruptionCost * 0.6 + signal.repetitionPenalty * 0.4

        // 各维度贡献（用于明细）
        let breakdown = HoloProactivityBreakdown(
            positiveComponent: positive * 100,
            negativeComponent: negative * 100,
            valueContribution: signal.value,
            confidenceContribution: signal.confidence,
            actionabilityContribution: signal.actionability,
            noveltyContribution: signal.novelty,
            timingContribution: signal.timingFitness,
            interruptionDeduction: signal.interruptionCost,
            repetitionDeduction: signal.repetitionPenalty
        )

        // 最终评分（0~100）
        let rawScore = (positive - negative) * 100
        let score = Swift.max(0, Swift.min(100, rawScore))

        // 分档
        let tier: HoloProactivityTier
        // 未授权 → 永不 notify，最多 store
        if !signal.userAuthorized && score >= thresholds.storeThreshold {
            tier = score >= thresholds.notifyThreshold ? .store : (score >= thresholds.watchThreshold ? .store : .watch)
        } else if score >= thresholds.notifyThreshold && signal.userAuthorized {
            tier = .notify
        } else if score >= thresholds.storeThreshold {
            tier = .store
        } else if score >= thresholds.watchThreshold {
            tier = .watch
        } else {
            tier = .ignore
        }

        return HoloProactivityScore(
            score: score,
            tier: tier,
            breakdown: breakdown
        )
    }
}

// MARK: - Outcome Review

/// Action Candidate 执行后的效果回看记录。
nonisolated struct HoloOutcomeReview: Equatable, Sendable, Codable {
    /// 关联的 Action ID。
    var actionID: String
    /// 来源 claim ID。
    var sourceClaimID: String?
    /// 用户是否确认、修改或取消。
    var userDecision: HoloOutcomeUserDecision
    /// 目标指标。
    var targetMetricKey: String
    /// 观察窗口（天）。
    var observationWindowDays: Int
    /// 后续是否执行。
    var actionExecuted: Bool
    /// 指标变化结果。
    var metricOutcome: HoloMetricOutcome
    /// 是否继续、调整或停止关注。
    var followUpDecision: HoloFollowUpDecision
    /// 回看时间。
    var reviewedAt: Date

    init(
        actionID: String, sourceClaimID: String? = nil,
        userDecision: HoloOutcomeUserDecision, targetMetricKey: String,
        observationWindowDays: Int = 14, actionExecuted: Bool,
        metricOutcome: HoloMetricOutcome, followUpDecision: HoloFollowUpDecision,
        reviewedAt: Date = Date()
    ) {
        self.actionID = actionID
        self.sourceClaimID = sourceClaimID
        self.userDecision = userDecision
        self.targetMetricKey = targetMetricKey
        self.observationWindowDays = observationWindowDays
        self.actionExecuted = actionExecuted
        self.metricOutcome = metricOutcome
        self.followUpDecision = followUpDecision
        self.reviewedAt = reviewedAt
    }
}

nonisolated enum HoloOutcomeUserDecision: String, Codable, Equatable, Sendable {
    case confirmed   // 用户确认执行
    case modified    // 用户修改后执行
    case cancelled   // 用户取消
    case ignored     // 用户忽略
}

nonisolated enum HoloMetricOutcome: String, Codable, Equatable, Sendable {
    case improved       // 指标改善
    case noChange       // 无变化
    case deteriorated   // 指标恶化
    case cannotDetermine // 无法判断（数据不足）
}

nonisolated enum HoloFollowUpDecision: String, Codable, Equatable, Sendable {
    case continueWatching  // 继续关注
    case adjust            // 调整建议
    case stopWatching      // 停止关注
}

// MARK: - Outcome Review Engine

nonisolated enum HoloOutcomeReviewEngine {

    /// 根据 Action 执行后的指标变化生成效果回看。
    /// 效果回看只能表达相关变化，不把行动与结果自动写成因果。
    static func review(
        actionID: String,
        sourceClaimID: String?,
        userDecision: HoloOutcomeUserDecision,
        targetMetricKey: String,
        actionExecuted: Bool,
        beforeValue: Double?,
        afterValue: Double?,
        observationWindowDays: Int = 14,
        improvementDirection: HoloImprovementDirection = .higherIsBetter
    ) -> HoloOutcomeReview {
        let outcome = determineOutcome(
            before: beforeValue, after: afterValue,
            actionExecuted: actionExecuted, improvementDirection: improvementDirection
        )

        let followUp: HoloFollowUpDecision
        switch outcome {
        case .improved:
            followUp = actionExecuted ? .adjust : .continueWatching
        case .noChange:
            followUp = .continueWatching
        case .deteriorated:
            followUp = .adjust
        case .cannotDetermine:
            followUp = .continueWatching
        }

        return HoloOutcomeReview(
            actionID: actionID, sourceClaimID: sourceClaimID,
            userDecision: userDecision, targetMetricKey: targetMetricKey,
            observationWindowDays: observationWindowDays,
            actionExecuted: actionExecuted,
            metricOutcome: outcome, followUpDecision: followUp
        )
    }

    /// 生成效果回看的用户可读表达（不写因果）。
    static func renderOutcome(_ review: HoloOutcomeReview) -> String {
        let actionDesc = review.actionExecuted ? "执行后" : "未执行期间"
        switch review.metricOutcome {
        case .improved:
            return "\(actionDesc)，\(review.targetMetricKey)有所改善。注意：这不代表行动直接带来改善。"
        case .noChange:
            return "\(actionDesc)，\(review.targetMetricKey)没有明显变化。"
        case .deteriorated:
            return "\(actionDesc)，\(review.targetMetricKey)有所下降。这不一定是行动带来的。"
        case .cannotDetermine:
            return "观察窗口内数据不足，无法判断\(review.targetMetricKey)的变化。"
        }
    }

    private static func determineOutcome(
        before: Double?, after: Double?,
        actionExecuted: Bool, improvementDirection: HoloImprovementDirection
    ) -> HoloMetricOutcome {
        guard let before = before, let after = after else {
            return .cannotDetermine
        }
        // 变化幅度 < 5% 视为无变化
        let relativeChange = before != 0 ? (after - before) / abs(before) : (after - before)
        if abs(relativeChange) < 0.05 {
            return .noChange
        }
        let isImprovement = improvementDirection == .higherIsBetter ? after > before : after < before
        return isImprovement ? .improved : .deteriorated
    }
}

nonisolated enum HoloImprovementDirection: String, Equatable, Sendable {
    case higherIsBetter  // 指标越高越好（如步数、睡眠）
    case lowerIsBetter   // 指标越低越好（如消费、压力）
}
