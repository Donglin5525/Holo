//
//  MemoryInsightActionPromptBuilder.swift
//  Holo
//
//  将记忆长廊卡片行动候选转换为 HoloAI 可继续追问的预填文本。
//

import Foundation

enum MemoryInsightActionPromptBuilder {

    static func chatPrefill(
        for action: InsightActionCandidate,
        card: MemoryInsightCard
    ) -> String? {
        guard case .reflectionQuestion(let question) = action.payload else {
            return nil
        }

        return """
        基于这张记忆长廊洞察继续分析：
        \(card.title)
        \(card.body)

        我想追问：\(question)
        """
    }
}
