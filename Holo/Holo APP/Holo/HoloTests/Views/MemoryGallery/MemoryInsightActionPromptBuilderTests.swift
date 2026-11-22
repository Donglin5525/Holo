import XCTest
@testable import Holo

final class MemoryInsightActionPromptBuilderTests: XCTestCase {

    func testReflectionQuestionBuildsChatPrefillWithCardContext() {
        let card = MemoryInsightCard(
            id: "habit-break",
            type: .habit,
            title: "一周节奏被固定支出主导",
            body: "习惯出现断连，值得回看触发点和可调整空间。",
            evidence: [],
            suggestedQuestion: nil,
            patternType: "habit_break"
        )
        let action = InsightActionCandidate(
            id: "action-1",
            cardId: card.id,
            type: .reflectionQuestion,
            title: "回顾断连原因",
            payload: .reflectionQuestion("这次习惯断连的原因是什么？有什么可以调整的？"),
            confidence: 0.7
        )

        let prompt = MemoryInsightActionPromptBuilder.chatPrefill(for: action, card: card)

        XCTAssertEqual(
            prompt,
            """
            基于这张记忆长廊洞察继续分析：
            一周节奏被固定支出主导
            习惯出现断连，值得回看触发点和可调整空间。

            我想追问：这次习惯断连的原因是什么？有什么可以调整的？
            """
        )
    }

    func testNonReflectionActionDoesNotBuildChatPrefill() {
        let card = MemoryInsightCard(
            id: "task-overdue",
            type: .task,
            title: "逾期待办变多",
            body: "有几件事需要收口。",
            evidence: [],
            suggestedQuestion: nil
        )
        let action = InsightActionCandidate(
            id: "action-2",
            cardId: card.id,
            type: .createTask,
            title: "创建清理待办任务",
            payload: .taskDraft(title: "20 分钟清理逾期待办", dueDate: nil, priority: nil),
            confidence: 0.8
        )

        XCTAssertNil(MemoryInsightActionPromptBuilder.chatPrefill(for: action, card: card))
    }

    func testInsightFollowUpContextInjectsIntoChatIntentAndCloudBrief() {
        let insightID = UUID(uuidString: "44444444-4444-4444-4444-444444444441")!
        let followUp = HoloInsightFollowUpContext(
            insightID: insightID,
            periodLabel: "本周观察",
            periodRange: "11月15日 - 11月21日",
            title: "早睡日的外卖消费明显更克制",
            summary: "过去两周作息与餐饮支出存在明显联动。",
            cards: [
                .init(
                    title: "早睡日的外卖消费明显更克制",
                    body: "过去两周，你在 23:30 前入睡的日子里，次日餐饮与外卖支出比平时低了 18%。"
                )
            ]
        )

        var context = UserContext.empty
        let section = InsightFollowUpContextSection()
        XCTAssertNil(section.chatBlock(context), "未挂载洞察追问时不应注入 chatBlock")
        XCTAssertNil(section.intentBlock(context), "未挂载洞察追问时不应注入 intentBlock")

        context.insightFollowUp = followUp
        let chatBlock = section.chatBlock(context)
        XCTAssertNotNil(chatBlock)
        XCTAssertTrue(chatBlock?.contains("早睡日的外卖消费明显更克制") == true)
        XCTAssertTrue(chatBlock?.contains("次日餐饮与外卖支出比平时低了 18%") == true)
        XCTAssertTrue(chatBlock?.contains("11月15日 - 11月21日") == true)

        let intentBlock = section.intentBlock(context)
        XCTAssertNotNil(intentBlock)
        XCTAssertTrue(intentBlock?.contains("不得触发 clarification") == true)

        let cloudBrief = followUp.makeCloudAnalysisBrief()
        XCTAssertTrue(cloudBrief.contains("本周观察 · 11月15日 - 11月21日"))
        XCTAssertTrue(cloudBrief.contains("次日餐饮与外卖支出比平时低了 18%"))
        XCTAssertEqual(followUp.previewBody, "过去两周，你在 23:30 前入睡的日子里，次日餐饮与外卖支出比平时低了 18%。")
    }
}
