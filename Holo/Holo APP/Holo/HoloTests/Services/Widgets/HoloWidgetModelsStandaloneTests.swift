import Foundation

@main
struct HoloWidgetModelsStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() throws {
        testDeepLinkParsesVoiceEntry()
        testDeepLinkBuildsQuickActionURLs()
        testFinanceSnapshotComparesBudgetAgainstTimeProgress()
        testThoughtMemorySnapshotProtectsPrivateContentByDefault()
        try testSnapshotStoreRoundTripsJSON()
        print("HoloWidgetModels standalone tests passed")
    }

    private static func testDeepLinkParsesVoiceEntry() {
        let target = HoloWidgetDeepLink.parse(URL(string: "holo://ai?voiceInput=true")!)

        expect(target == .ai(voiceInput: true), "语音入口应解析为 AI + voiceInput=true")
    }

    private static func testDeepLinkBuildsQuickActionURLs() {
        expect(HoloWidgetQuickAction.askHolo.deepLink.absoluteString == "holo://ai", "问 Holo 深链不正确")
        expect(HoloWidgetQuickAction.addTransaction.deepLink.absoluteString == "holo://finance/add", "记一笔深链不正确")
        expect(HoloWidgetQuickAction.recordThought.deepLink.absoluteString == "holo://thoughts/new", "写想法深链不正确")
        expect(HoloWidgetQuickAction.addTask.deepLink.absoluteString == "holo://tasks/new", "加待办深链不正确")
    }

    private static func testFinanceSnapshotComparesBudgetAgainstTimeProgress() {
        let snapshot = HoloWidgetFinanceSnapshot(
            todayExpense: 128.5,
            todayIncome: 0,
            monthExpense: 620,
            monthBudget: 1_000,
            dayOfMonth: 14,
            daysInMonth: 30,
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        expect(snapshot.budgetProgress == 0.62, "预算进度应等于本月支出 / 本月预算")
        expect(abs(snapshot.timeProgress - 0.4667) < 0.001, "时间进度应等于当前日期 / 当月天数")
        expect(snapshot.budgetStatus == .aheadOfTime, "预算进度明显快于时间进度时应提醒")
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
    }
}
