//
//  HoloExpressionDecisionEngine.swift
//  Holo
//
//  用结构化规则决定 Holo 的表达强度，避免让 LLM 自己猜。
//

import Foundation

enum HoloExpressionDecisionEngine {

    static func decide(
        evidenceCount: Int,
        independentDimensionCount: Int,
        isRelatedToUserFocus: Bool = false,
        userExplicitlyAsksForAdvice: Bool = false,
        hasConfirmedMilestone: Bool = false,
        containsSensitiveHealthOrMindSignal: Bool = false,
        feedbackShowsAdviceUseful: Bool = false
    ) -> HoloExpressionDecision {
        if hasConfirmedMilestone {
            return decision(
                level: .celebrate,
                confidence: 0.85,
                evidenceCount: evidenceCount,
                allowed: ["具体庆祝", "引用事实证据"],
                reason: "已确认的阶段进展或里程碑"
            )
        }

        if userExplicitlyAsksForAdvice || feedbackShowsAdviceUseful {
            return decision(
                level: .suggestAction,
                confidence: 0.8,
                evidenceCount: evidenceCount,
                allowed: ["给一个最小动作", "先确认用户当前目标"],
                reason: userExplicitlyAsksForAdvice ? "用户明确求助" : "用户反馈此类建议有用"
            )
        }

        if isRelatedToUserFocus {
            return decision(
                level: .remind,
                confidence: 0.72,
                evidenceCount: evidenceCount,
                allowed: ["轻提醒", "连接用户关注目标"],
                reason: "与用户档案或当前目标相关"
            )
        }

        if evidenceCount >= 3,
           independentDimensionCount >= 3,
           !containsSensitiveHealthOrMindSignal {
            return decision(
                level: .summarize,
                confidence: 0.7,
                evidenceCount: evidenceCount,
                allowed: ["可能", "像是", "值得留意", "轻归纳"],
                reason: "存在至少三个独立信号"
            )
        }

        return decision(
            level: .observe,
            confidence: min(0.6, max(0.35, Double(evidenceCount) * 0.18)),
            evidenceCount: evidenceCount,
            allowed: ["看到", "记录到", "先观察"],
            reason: "证据不足以做强归纳"
        )
    }

    static func decide(for context: UserContext, userText: String? = nil) -> HoloExpressionDecision {
        let evidenceCount = [
            !context.transactions.recentTransactions.isEmpty,
            context.habits.totalActive > 0,
            context.tasks.dueToday > 0 || context.tasks.completedToday > 0,
            context.thoughts.totalThoughts > 0,
            context.memorySummary?.lines.isEmpty == false
        ].filter { $0 }.count

        let asksForAdvice = userText.map { text in
            ["怎么办", "怎么做", "建议", "帮我", "如何"].contains { text.contains($0) }
        } ?? false

        let relatedToFocus = context.goalContext?.isEmpty == false
            || context.profileContext?.isEmpty == false
            || !context.habits.focusTopicLines.isEmpty

        return decide(
            evidenceCount: evidenceCount,
            independentDimensionCount: evidenceCount,
            isRelatedToUserFocus: relatedToFocus,
            userExplicitlyAsksForAdvice: asksForAdvice
        )
    }

    private static func decision(
        level: HoloExpressionLevel,
        confidence: Double,
        evidenceCount: Int,
        allowed: [String],
        reason: String
    ) -> HoloExpressionDecision {
        HoloExpressionDecision(
            level: level,
            confidence: confidence,
            evidenceCount: evidenceCount,
            allowedVerbs: allowed,
            bannedPhrases: ["导致", "证明", "说明一定因为", "你就是", "人格", "焦虑了", "压力很大"],
            reason: reason
        )
    }
}

