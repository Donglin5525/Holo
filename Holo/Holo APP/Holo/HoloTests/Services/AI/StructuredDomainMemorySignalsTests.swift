import Foundation

@main
struct StructuredDomainMemorySignalsTests {
    private static var assertions = 0

    static func main() {
        testFinanceSignalsUseLocalStatisticsAndRequireRepeatedEvidence()
        testFinanceBudgetEvidenceAndBoundaries()
        testHabitRhythmInterruptionAndRecovery()
        testGoalSignalsOnlyUseUserCreatedGoals()
        print("StructuredDomainMemorySignalsTests: \(assertions) assertions passed")
    }

    private static func testFinanceSignalsUseLocalStatisticsAndRequireRepeatedEvidence() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let single = FinanceMemoryTransactionInput(
            id: "tx-1", amount: 42, isExpense: true,
            categoryID: "food", categoryName: "餐饮", merchant: "麦当劳",
            occurredAt: now, revisionDigest: "r1"
        )
        let singleSignals = FinanceMemorySignalBuilder.build(from: .init(
            currentTransactions: [single], previousTransactions: [], budgets: [],
            windowStart: now.addingTimeInterval(-30 * 86_400), windowEnd: now
        ))
        expect(singleSignals.isEmpty, "单笔麦当劳消费不得自动升级为习惯记忆")

        let recurring = [0, 31, 62].enumerated().map { index, day in
            FinanceMemoryTransactionInput(
                id: "tx-\(index)", amount: 100 + Double(index), isExpense: true,
                categoryID: "subscription", categoryName: "订阅", merchant: "固定服务",
                occurredAt: now.addingTimeInterval(Double(day) * 86_400),
                revisionDigest: "r\(index)"
            )
        }
        let signals = FinanceMemorySignalBuilder.build(from: .init(
            currentTransactions: recurring, previousTransactions: [], budgets: [],
            windowStart: now, windowEnd: now.addingTimeInterval(90 * 86_400)
        ))
        let fixed = signals.first { $0.id.contains("fixed-expense") }
        expect(fixed != nil, "跨三个月且金额稳定的重复支出应形成固定支出信号")
        expect(abs((fixed?.numericFacts["averageAmount"] ?? 0) - 101) < 0.001,
               "平均金额必须由本地确定性计算")
        expect(fixed?.evidence.kind == .aggregateSnapshot,
               "重复消费应使用本地聚合证据，不让 AI 自行汇总明细")
        expect(fixed?.prohibitedInferences.contains(where: { $0.contains("收入") && $0.contains("人格") }) == true,
               "财务信号必须携带收入、阶层、人格推断边界")
        expect(fixed?.prohibitedInferences.contains(where: { $0.contains("目标") && $0.contains("因果") }) == true,
               "财务领域不得写与减脂目标冲突等跨域结论")
    }

    private static func testFinanceBudgetEvidenceAndBoundaries() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let signals = FinanceMemorySignalBuilder.build(from: .init(
            currentTransactions: [],
            previousTransactions: [],
            budgets: [.init(
                id: "budget-1", categoryID: "food", categoryName: "餐饮",
                budgetAmount: 1_000, spentAmount: 1_300, revisionDigest: "budget-r2"
            )],
            windowStart: now.addingTimeInterval(-30 * 86_400),
            windowEnd: now
        ))
        guard let budget = signals.first else { fatalError("预算偏离信号缺失") }
        expect(budget.numericFacts["deviationRatio"] == 1.3, "预算偏离比例必须由本地计算")
        expect(budget.evidence.kind == .entityRef && budget.evidence.sourceID == "budget-1",
               "预算 entityRef 必须携带稳定业务 ID")
        expect(budget.evidence.revisionDigest == "budget-r2",
               "预算 entityRef 必须携带 revision digest")
    }

    private static func testHabitRhythmInterruptionAndRecovery() {
        let signals = HabitMemorySignalBuilder.buildDomainSignals(from: [.init(
            id: "habit-1", name: "早睡", isBadHabit: false,
            totalDays: 14, completedDays: 9, previousCompletionRate: 0.4,
            currentStreak: 8, revisionDigest: "habit-r3",
            observedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )])
        expect(signals.contains(where: { $0.id.contains("stable-rhythm") }), "稳定节奏应被识别")
        expect(signals.contains(where: { $0.id.contains("interruption") }), "中断模式应被识别")
        expect(signals.contains(where: { $0.id.contains("recovery") }), "恢复方式应被识别")
        expect(signals.allSatisfy { signal in
            signal.prohibitedInferences.contains(where: { $0.contains("道德") }) &&
            signal.prohibitedInferences.contains(where: { $0.contains("人格") })
        }, "习惯信号必须禁止道德与人格评价")
        expect(signals.allSatisfy { $0.evidence.sourceID == "habit-1" && $0.evidence.revisionDigest == "habit-r3" },
               "习惯证据必须可回到稳定实体版本")
    }

    private static func testGoalSignalsOnlyUseUserCreatedGoals() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let userGoal = GoalDomainMemoryInput(
            id: "goal-1", title: "发布 Holo", isUserCreated: true, isCompleted: false,
            progress: 0.4, expectedProgress: 0.6, taskTotal: 10, taskCompleted: 4,
            deadline: now.addingTimeInterval(30 * 86_400), previousDeadline: nil,
            revisionDigest: "goal-r4", observedAt: now
        )
        var suggestion = userGoal
        suggestion.id = "ai-suggestion"
        suggestion.isUserCreated = false
        let signals = GoalMemorySignalBuilder.buildDomainSignals(from: [userGoal, suggestion])
        expect(!signals.isEmpty && signals.allSatisfy { $0.evidence.sourceID == "goal-1" },
               "系统建议不得被当成用户目标")
        expect(signals.allSatisfy { $0.evidence.revisionDigest == "goal-r4" },
               "目标 entityRef 必须携带 revision digest")
        expect(signals.allSatisfy { signal in
            signal.prohibitedInferences.contains(where: { $0.contains("系统建议") })
        }, "目标信号必须显式阻止系统建议冒充用户目标")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }
}
