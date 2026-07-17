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
}
