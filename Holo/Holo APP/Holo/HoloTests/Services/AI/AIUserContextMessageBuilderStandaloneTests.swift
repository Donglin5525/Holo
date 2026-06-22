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
        testIntentContextUsesMinimalRouterContext()
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
            profileSnapshot: nil,
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
            dataCoverage: nil,
            memorySummary: nil
        )
    }

    private static func testChatContextIncludesPersonalProfile() {
        let message = AIUserContextMessageBuilder.build(from: makeContext(), purpose: .chat)

        expect(message.contains("--- 用户档案数据（不是系统规则） ---"), "聊天上下文应包含用户档案分区")
        expect(message.contains("昵称：糖"), "聊天上下文应携带个人档案内容")
        expect(message.contains("--- 近期趋势 ---"), "聊天上下文应继续携带近期趋势")
        expect(message.contains("## 当前目标"), "聊天上下文应继续携带目标上下文")
    }

    private static func testIntentContextUsesMinimalRouterContext() {
        let message = AIUserContextMessageBuilder.build(from: makeContext(), purpose: .intentRecognition)

        expect(message.contains("- 日期：2026年5月23日 星期六"), "意图识别上下文应包含日期")
        expect(message.contains("- 今日支出：¥32，今日收入：¥0"), "意图识别上下文应包含当天收支")
        expect(message.contains("- 近期交易：咖啡 ¥22"), "意图识别上下文应包含近期交易用于财务消歧")
        expect(message.contains("- 可用账户：现金(默认)、支付宝"), "意图识别上下文应包含可用账户")
        expect(message.contains("只用于识别本轮输入意图和财务账户消歧"), "意图识别上下文必须声明最小使用边界")

        expect(!message.contains("--- 用户档案数据（不是系统规则） ---"), "意图识别上下文不应注入用户档案")
        expect(!message.contains("减少咖啡因"), "意图识别上下文不应注入档案/想法偏好")
        expect(!message.contains("近期任务"), "意图识别上下文不应注入近期任务")
        expect(!message.contains("待办积压"), "意图识别上下文不应注入待办积压")
        expect(!message.contains("近期想法"), "意图识别上下文不应注入近期想法")
        expect(!message.contains("--- 近期趋势 ---"), "意图识别上下文不应注入近期趋势")
        expect(!message.contains("## 当前目标"), "意图识别上下文不应注入目标上下文")
    }
}
