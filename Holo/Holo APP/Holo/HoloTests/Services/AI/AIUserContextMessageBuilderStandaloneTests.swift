import Foundation

@main
struct AIUserContextMessageBuilderStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testChatContextIncludesPersonalProfile()
        testIntentContextIncludesProfileAsDisambiguationOnly()
        print("AIUserContextMessageBuilder standalone tests passed")
    }

    private static func makeContext() -> UserContext {
        UserContext(
            todayDate: "2026年5月23日 星期六",
            transactions: TransactionSummary(
                todayExpense: "¥32",
                todayIncome: "¥0",
                recentTransactions: ["咖啡 ¥22"]
            ),
            habits: HabitSummary(
                totalActive: 2,
                todayCompleted: 1,
                todayTotal: 2,
                todayNegativeChecked: 0,
                todayNegativeTotal: 1,
                recentCheckIns: ["戒烟: 未发生", "跑步: 已打卡"],
                activeHabitNames: ["戒烟", "跑步"],
                focusSummaries: [],
                focusTopicLines: ["用户档案出现戒除/减少型主题"]
            ),
            tasks: TaskSummary(
                dueToday: 3,
                completedToday: 1,
                overdueCount: 0,
                recentTasks: ["○ 写周报"],
                activeTaskSummaries: ["○ 写周报"]
            ),
            thoughts: ThoughtSummary(
                recentThoughts: ["最近想减少咖啡因"],
                totalThoughts: 4
            ),
            accounts: AccountSummary(accountList: "现金(默认)、支付宝", defaultAccountName: "现金"),
            profileContext: """
            # 个人档案
            - 昵称：糖
            - 当前关注：戒烟、减少咖啡因
            """,
            recentTrend: UserRecentTrend(
                weekExpenseTotal: "¥280",
                weekExpenseChange: "-12%",
                weekHabitCompletionRate: "71%",
                weekTaskCompletedCount: 5,
                topExpenseCategory: "餐饮",
                dailyInsightSummary: "消费更克制"
            ),
            goalContext: """
            ## 当前目标

            - 戒烟 90 天
            """,
            profileSnapshot: nil,
            dataCoverage: nil,
            memorySummary: nil
        )
    }

    private static func testChatContextIncludesPersonalProfile() {
        let message = AIUserContextMessageBuilder.build(from: makeContext(), purpose: .chat)

        expect(message.contains("--- 用户档案 ---"), "聊天上下文应包含用户档案分区")
        expect(message.contains("昵称：糖"), "聊天上下文应携带个人档案内容")
        expect(message.contains("--- 近期趋势 ---"), "聊天上下文应继续携带近期趋势")
        expect(message.contains("## 当前目标"), "聊天上下文应继续携带目标上下文")
    }

    private static func testIntentContextIncludesProfileAsDisambiguationOnly() {
        let message = AIUserContextMessageBuilder.build(from: makeContext(), purpose: .intentRecognition)

        expect(message.contains("--- 用户档案 ---"), "意图识别上下文应包含用户档案分区")
        expect(message.contains("减少咖啡因"), "意图识别上下文应携带档案偏好用于消歧")
        expect(message.contains("只能作为消歧和个性化依据"), "意图识别上下文必须约束档案优先级")
        expect(message.contains("不得覆盖用户当前明确指令"), "意图识别上下文必须声明当前指令优先")
    }
}
