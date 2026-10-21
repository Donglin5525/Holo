#if DEBUG && targetEnvironment(simulator)
import Foundation
import CoreData

/// 只在显式 UI 验收参数下写入虚构数据，正式 App 和真机均不编译此入口。
@MainActor
enum GoalProgressUITestSeeder {
    static func seedIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_GOAL_PROGRESS") else { return }
        DarkModeManager.shared.currentSetting = ProcessInfo.processInfo.arguments.contains("UITEST_GOAL_DARK") ? .dark : .light
        let context = CoreDataStack.shared.viewContext
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", "验收·北海道旅行")
        guard (try? context.count(for: request)) == 0 else { return }
        let calendar = Calendar.current, now = Date()
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now }
        func habit(_ name: String, unit: String, bad: Bool = false) -> Habit {
            let item = Habit.create(in: context, name: name, icon: "figure.run", color: "#EA794C", type: .numeric,
                targetValue: 30, unit: unit, isBadHabit: bad)
            item.createdAt = day(30)
            return item
        }
        func record(_ habit: Habit, _ value: Double, ago: Int) {
            let row = HabitRecord.createNumeric(in: context, habit: habit, value: value)
            row.date = calendar.date(byAdding: .hour, value: 10, to: day(ago)) ?? day(ago)
            row.createdAt = row.date
        }
        let reading = habit("验收·阅读", unit: "分钟")
        let run = habit("验收·跑步", unit: "公里")
        let tea = habit("验收·奶茶", unit: "杯", bad: true)
        record(reading, 50, ago: 1); record(reading, 60, ago: 2)
        record(run, 10, ago: 1); record(run, 5, ago: 2)
        record(tea, 1, ago: 2)
        let task = TodoTask.create(in: context, title: "验收·核对出行证件")
        let account = Account.create(in: context, name: "验收·旅行专款", type: AccountType.bank.rawValue, initialBalance: 6000)
        let travel = Goal.create(in: context, title: "验收·北海道旅行", summary: nil, domain: .finance,
            desiredOutcome: "旅行专款达到18000元，提前做好出发准备", motivation: nil,
            deadline: calendar.date(byAdding: .month, value: 3, to: now), allowAIContext: false)
        travel.goalKindEnum = .cumulative; travel.metricSourceEnum = .ledger; travel.metricTargetValueDouble = 18000
        let fitness = Goal.create(in: context, title: "验收·跑得更远", summary: nil, domain: .health,
            desiredOutcome: "最近七天累计跑40公里", motivation: nil, deadline: nil, allowAIContext: false)
        func binding(_ habit: Habit, role: GoalPlanBindingRole, metric: GoalRequirementMetric, target: Double,
                     comparison: GoalResultComparison = .reach) -> GoalPlanBindingV2 {
            GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: role,
                displayTitle: habit.name, isGoalOwned: false,
                requirement: GoalBindingRequirement(metric: metric, target: target, comparison: comparison))
        }
        do {
            let source = GoalPlanResultSourceV2(sourceType: .ledger, sourceID: account.id, unit: "元", aggregation: .sum,
                comparison: .reach, targetValue: 18000,
                ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id))
            for (goal, result, bindings) in [
                (travel, Optional(source), [binding(reading, role: .action, metric: .sum, target: 120),
                    binding(run, role: .action, metric: .eventCount, target: 3),
                    binding(tea, role: .constraint, metric: .sum, target: 2, comparison: .stayBelow),
                    GoalPlanBindingV2(id: UUID(), entityType: .task, entityID: task.id, role: .action, displayTitle: task.title)]),
                (fitness, nil, [binding(run, role: .result, metric: .sum, target: 40)])
            ] {
                let payload = GoalPlanPayloadV2(schemaVersion: 3,
                    intent: GoalPlanIntentV2(originalWish: goal.title, successCriteria: goal.desiredOutcome, deadline: goal.deadline),
                    resultSource: result, bindings: bindings,
                    basis: GoalPlanDecisionBasisV2(origin: .manual, confirmedAt: now))
                _ = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                    revisionNumber: 1, baseRevisionID: nil, operationID: UUID(), effectiveFrom: day(7), payload: payload, legacySummary: nil)
            }
            try context.save()
            UserDefaults.standard.set(travel.id.uuidString, forKey: "holo.today.focusGoalID")
            HabitRepository.shared.loadActiveHabits()
            GoalRepository.shared.loadGoals()
        } catch { assertionFailure("目标进展验收种子失败：\(error)") }
    }
}
#endif
