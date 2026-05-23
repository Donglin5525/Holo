//
//  InsightActionCandidateBuilder.swift
//  Holo
//
//  洞察行动候选生成器
//  基于规则匹配，硬编码 3-5 个高频场景
//

import Foundation

struct InsightActionCandidateBuilder {

    /// 从卡片生成行动候选（每卡最多 1 个）
    static func buildCandidates(
        cards: [MemoryInsightCard],
        context: MemoryInsightContext?
    ) -> [InsightActionCandidate] {
        guard InsightFeatureFlags.actionCandidateEnabled else { return [] }

        var candidates: [InsightActionCandidate] = []

        for card in cards {
            if let candidate = matchCandidate(for: card, context: context) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    // MARK: - Rule Matching

    private static func matchCandidate(
        for card: MemoryInsightCard,
        context: MemoryInsightContext?
    ) -> InsightActionCandidate? {
        // 任务逾期 ≥ 3
        if card.type == .task || card.moduleHint == "task" {
            if context?.tasks.overdueCount ?? 0 >= 3 {
                return InsightActionCandidate(
                    id: UUID().uuidString,
                    cardId: card.id,
                    type: .createTask,
                    title: "创建清理待办任务",
                    payload: .taskDraft(
                        title: "20 分钟清理逾期待办",
                        dueDate: Date(),
                        priority: nil
                    ),
                    confidence: 0.8
                )
            }
        }

        // 习惯断连
        if card.type == .habit || card.moduleHint == "habit" {
            let patternType = card.patternType ?? ""
            if patternType == "habit_break" || card.title.contains("断连") {
                return InsightActionCandidate(
                    id: UUID().uuidString,
                    cardId: card.id,
                    type: .reflectionQuestion,
                    title: "回顾断连原因",
                    payload: .reflectionQuestion("这次习惯断连的原因是什么？有什么可以调整的？"),
                    confidence: 0.7
                )
            }
        }

        // 消费偏离
        if card.type == .finance || card.moduleHint == "finance" {
            let patternType = card.patternType ?? ""
            if patternType == "spending_increase" {
                return InsightActionCandidate(
                    id: UUID().uuidString,
                    cardId: card.id,
                    type: .budgetReminder,
                    title: "设置消费提醒",
                    payload: .budgetReminderDraft(categoryId: nil, amount: nil),
                    confidence: 0.6
                )
            }
        }

        // 恢复迹象
        let patternType = card.patternType ?? ""
        if patternType == "recovery" {
            return InsightActionCandidate(
                id: UUID().uuidString,
                cardId: card.id,
                type: .reflectionQuestion,
                title: "记录恢复经验",
                payload: .reflectionQuestion("这次恢复是怎么发生的？"),
                confidence: 0.7
            )
        }

        return nil
    }
}
