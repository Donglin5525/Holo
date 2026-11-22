import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloWidgetModelsStandaloneTests.main()
    }
}
#endif
struct HoloWidgetModelsStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() throws {
        testDeepLinkParsesVoiceEntry()
        testDeepLinkParsesFinanceAnalysis()
        testDeepLinkBuildsQuickActionURLs()
        testDeepLinkParsesSecondBatchEntries()
        testFinanceSnapshotComparesBudgetAgainstTimeProgress()
        testThoughtMemorySnapshotProtectsPrivateContentByDefault()
        testHabitSnapshotComputesRemaining()
        testDeepLinkParsesNextBatchEntries()
        testHealthSnapshotComputesProgressAndFormatting()
        testFinanceSnapshotComputesTodayExpense()
        try testSnapshotStoreRoundTripsJSON()
        try testSnapshotStoreResolvesInsightSelection()
        print("HoloWidgetModels standalone tests passed")
    }

    private static func testDeepLinkParsesVoiceEntry() {
        let target = HoloWidgetDeepLink.parse(URL(string: "holo://ai?voiceInput=true")!)

        expect(target == .ai(voiceInput: true), "语音入口应解析为 AI + voiceInput=true")
    }

    private static func testDeepLinkParsesFinanceAnalysis() {
        let target = HoloWidgetDeepLink.parse(URL(string: "holo://finance/analysis")!)

        expect(target == .financeAnalysis, "今日收支小组件应解析为财务分析深链，而不是记账")
        // 回归保护：记账深链仍应独立可用
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://finance/add")!) == .addTransaction, "记一笔深链不应被影响")
    }

    private static func testDeepLinkParsesSecondBatchEntries() {
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://habits")!) == .habits, "习惯小组件深链应解析为 holo://habits")
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://tasks")!) == .tasks, "待办小组件深链应解析为 holo://tasks")
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://tasks/new")!) == .addTask, "加待办深链不应被 holo://tasks 覆盖")
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://goals/detail?id=11111111-1111-1111-1111-111111111111")!)
                == .goalDetail(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            "目标小组件深链应解析为带 id 的目标详情"
        )
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://anniversaries")!) == .anniversaries, "纪念日小组件深链应解析为 holo://anniversaries")
    }

    private static func testDeepLinkBuildsQuickActionURLs() {
        expect(HoloWidgetQuickAction.askHolo.deepLink.absoluteString == "holo://ai", "问 Holo 深链不正确")
        expect(HoloWidgetQuickAction.addTransaction.deepLink.absoluteString == "holo://finance/add", "记一笔深链不正确")
        expect(HoloWidgetQuickAction.recordThought.deepLink.absoluteString == "holo://thoughts/new", "写想法深链不正确")
        expect(HoloWidgetQuickAction.addTask.deepLink.absoluteString == "holo://tasks/new", "加待办深链不正确")
    }

    private static func testFinanceSnapshotComparesBudgetAgainstTimeProgress() {
        let snapshot = HoloWidgetFinanceSnapshot(
            monthExpense: 620,
            monthIncome: 8_500,
            monthBudget: 1_000,
            dayOfMonth: 14,
            daysInMonth: 30,
            weekExpense: nil,
            topCategories: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        expect(snapshot.budgetProgress == 0.62, "预算进度应等于本月支出 / 本月预算")
        expect(abs(snapshot.timeProgress - 0.4667) < 0.001, "时间进度应等于当前日期 / 当月天数")
        expect(snapshot.budgetStatus == .aheadOfTime, "预算进度明显快于时间进度时应提醒")
    }

    private static func testHabitSnapshotComputesRemaining() {
        let snapshot = HoloWidgetHabitSnapshot(
            completedToday: 3,
            totalToday: 5,
            longestStreakText: "34天",
            habits: [],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        expect(snapshot.remainingCount == 2, "剩余习惯数应等于总数减已完成")
        expect(HoloWidgetHabitSnapshot.empty().remainingCount == 0, "空数据时剩余数应为 0")
        expect(HoloWidgetGoalSnapshot.empty().goal == nil, "无进行中目标时快照应为空态")
    }

    private static func testThoughtMemorySnapshotProtectsPrivateContentByDefault() {
        let thoughtId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let snapshot = HoloWidgetThoughtMemorySnapshot(
            thoughtId: thoughtId,
            createdAt: Date(timeIntervalSince1970: 0),
            tags: ["产品灵感", "自我观察"],
            excerpt: "这是一段不应该默认出现在桌面上的原文",
            sourceHint: "来自一次夜间记录",
            showsOriginalExcerpt: false
        )

        expect(snapshot.displayText == "来自一次夜间记录", "默认隐私保护时应显示弱提示而不是原文")
        expect(snapshot.detailDeepLink.absoluteString == "holo://thoughts/detail?id=11111111-1111-1111-1111-111111111111", "想法详情深链不正确")
    }

    private static func testSnapshotStoreRoundTripsJSON() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holo-widget-store-tests-\(UUID().uuidString)", isDirectory: true)
        let store = HoloWidgetSnapshotStore(directoryURL: directory)
        let quickActions = HoloWidgetQuickActionsSnapshot.defaultSnapshot(date: Date(timeIntervalSince1970: 0))

        try store.writeQuickActions(quickActions)

        expect(store.readQuickActions() == quickActions, "快照存储应能读回快捷动作 JSON")

        let health = HoloWidgetHealthSnapshot.sample(date: Date(timeIntervalSince1970: 0))
        try store.writeHealth(health)
        expect(store.readHealth() == health, "快照存储应能读回健康快照 JSON")

        let memory = HoloWidgetMemorySnapshot.sample(date: Date(timeIntervalSince1970: 0))
        try store.writeMemory(memory)
        expect(store.readMemory() == memory, "快照存储应能读回记忆长廊快照 JSON")
    }

    private static func testDeepLinkParsesNextBatchEntries() {
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://health")!) == .health, "健康小组件深链应解析为 .health")
        expect(HoloWidgetDeepLink.parse(URL(string: "holo://home")!) == .dailyKanban, "今日全览深链应解析为 .dailyKanban")
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://memory?focus=insights")!) == .memoryGallery(focusInsights: true),
            "记忆长廊洞察深链应解析为 focusInsights=true"
        )
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://memory")!) == .memoryGallery(focusInsights: false),
            "记忆长廊默认深链应解析为 focusInsights=false"
        )
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444441")!
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://insight/detail?id=\(id.uuidString)")!) == .memoryInsight(id: id),
            "单条洞察深链应解析出 UUID"
        )
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://chat?prefill=hello")!) == .chat(prefill: "hello"),
            "AI 预填追问深链应解析出 prefill"
        )
        let followUpInsight = HoloWidgetInsightPoolSnapshot.sample().items[0]
        let followUpURL = followUpInsight.askHoloDeepLink
        let parsedFollowUp = HoloWidgetDeepLink.parse(followUpURL)
        expect(
            parsedFollowUp == .insightFollowUp(
                id: followUpInsight.id,
                fallbackPrefill: "展开说说这条发现：\(followUpInsight.title)"
            ),
            "小组件「追问 Holo」深链应携带 insightId 并解析为 .insightFollowUp"
        )
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://chat?insightId=not-a-uuid&prefill=fallback")!)
                == .chat(prefill: "fallback"),
            "insightId 非法时应安全降级为 .chat(prefill:)"
        )
        let taskId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        expect(
            HoloWidgetDeepLink.parse(URL(string: "holo://tasks/detail?id=\(taskId.uuidString)")!) == .taskDetail(id: taskId),
            "待办单行详情深链应解析出任务 UUID"
        )
        let goalSample = HoloWidgetGoalSnapshot.sample()
        expect(goalSample.allGoals.count == 3, "目标快照示例应包含 3 个目标供 Large 总览与编辑器选用")
    }

    private static func testHealthSnapshotComputesProgressAndFormatting() {
        let snapshot = HoloWidgetHealthSnapshot.sample(date: Date(timeIntervalSince1970: 0))
        expect(abs(snapshot.stepsProgress - 0.9275) < 0.001, "步数进度应为 steps / stepsGoal")
        expect(abs(snapshot.sleepProgress - 0.925) < 0.001, "睡眠进度应为 sleepHours / sleepGoalHours")
        expect(snapshot.sleepShortText == "7.4h", "睡眠短文案应保留一位小数")
        expect(snapshot.stepsShortText == "7.4k", "千级步数短文案应显示 k")
    }

    private static func testFinanceSnapshotComputesTodayExpense() {
        let snapshot = HoloWidgetFinanceSnapshot(
            monthExpense: 620,
            monthIncome: 8_500,
            monthBudget: 1_000,
            dayOfMonth: 14,
            daysInMonth: 30,
            weekExpense: [
                HoloWidgetDailyExpense(weekdayText: "六", amount: 50, isToday: false),
                HoloWidgetDailyExpense(weekdayText: "今", amount: 128.5, isToday: true)
            ],
            topCategories: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        expect(snapshot.todayExpense == 128.5, "今日支出应取 weekExpense 中 isToday == true 的金额")
    }

    private static func testSnapshotStoreResolvesInsightSelection() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holo-widget-insight-tests-\(UUID().uuidString)", isDirectory: true)
        let store = HoloWidgetSnapshotStore(directoryURL: directory)
        let now = Date()
        let pool = HoloWidgetInsightPoolSnapshot.sample(date: now)
        try store.writeInsightPool(pool)

        expect(store.resolvedInsightItem(on: now)?.id == pool.items[0].id, "未手选时应默认返回第一条洞察")

        let picked = pool.items[1]
        try store.writeInsightSelection(HoloWidgetInsightSelection(insightId: picked.id, date: now))
        expect(store.resolvedInsightItem(on: now)?.id == picked.id, "当天手动换条后应返回手选洞察")

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        expect(store.resolvedInsightItem(on: tomorrow)?.id == pool.items[0].id, "次日手选失效后应自动恢复第一条洞察")
    }
}

#if HOLO_XCTEST_BRIDGE
/// 回归保护：直接对真实 CoreData SQLite Store 执行快照刷新，防 NSPredicate 引用不存在的实体字段（2026-11-22 闪退实锤）。
@MainActor
final class HoloWidgetSnapshotServiceTests: XCTestCase {
    func testRefreshMemoryAndInsightSnapshotsExecuteValidCoreDataPredicates() async {
        HoloWidgetSnapshotService.shared.refreshMemorySnapshot(force: true)
        HoloWidgetSnapshotService.shared.refreshInsightSnapshot()
        await HoloWidgetSnapshotService.shared.refreshAllSnapshots()
    }
}
#endif
