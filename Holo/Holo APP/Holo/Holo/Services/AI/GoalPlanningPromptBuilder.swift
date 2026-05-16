//
//  GoalPlanningPromptBuilder.swift
//  Holo
//
//  目标规划每轮追问和草案生成的 prompt 构建
//

import Foundation

enum GoalPlanningPromptBuilder {
    static func questionPrompt(session: GoalPlanningSession, userContext: UserContext) -> String {
        """
        你是 Holo 的目标规划助手。你需要通过最多 3 轮追问，把用户的长期目标澄清成可执行计划。

        当前日期：\(userContext.todayDate)
        当前轮次：\(session.turnCount + 1)/\(session.maxTurns)
        用户已提供的信息：
        \(session.answers.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        请只回复一个简短追问，优先询问以下尚不明确的信息：
        1. 用户希望达到什么程度
        2. 用户为什么要做这个目标
        3. 截止时间、每周投入、当前基础或限制

        如果信息已经足够生成草案，请只回复：DRAFT_READY
        """
    }

    static func draftPrompt(session: GoalPlanningSession, userContext: UserContext) -> String {
        """
        你是 Holo 的目标规划助手。请根据用户信息生成 GoalDraft JSON。

        当前日期：\(userContext.todayDate)
        生成模式：\(session.mode.rawValue)
        用户信息：
        \(session.answers.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        输出要求：
        - 只输出 JSON，不要 Markdown
        - frequency 只能是 daily、weekly、monthly
        - type 只能是 checkIn 或 numeric
        - priority 只能是 0、1、2、3
        - deadlineText 和 dueDateText 使用 yyyy-MM-dd
        - 精简模式生成 2-4 个任务、1-2 个习惯
        - 完整模式生成 4-8 个任务、2-4 个习惯

        JSON 结构：
        {
          "id": "draft-uuid",
          "title": "目标标题",
          "summary": "目标说明",
          "domain": "learning|health|career|finance|life|project|other",
          "desiredOutcome": "期望结果",
          "motivation": "动机",
          "deadlineText": "yyyy-MM-dd 或 null",
          "tasks": [
            {
              "id": "task-1",
              "isSelected": true,
              "title": "任务标题",
              "dueDateText": "yyyy-MM-dd 或 null",
              "priority": 1,
              "note": "简短说明"
            }
          ],
          "habits": [
            {
              "id": "habit-1",
              "isSelected": true,
              "name": "习惯名称",
              "frequency": "daily",
              "targetCount": 1,
              "type": "checkIn",
              "unit": null,
              "targetValue": null
            }
          ],
          "missingInfoWarnings": []
        }
        """
    }
}
