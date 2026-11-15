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

    /// 目标界面减法重设计走查（2026-11-13；R2 补数据 2026-11-14）：列表五状态各造一张卡——
    /// 进行中量化（128/300 非零进度 + 期限）/ 进行中过程型（真实回顾摘要）/ 已暂停 /
    /// 已完成（终值 + 达成日）/ 已到期（齐数据 + 逾期胶囊）；幂等：
    /// 标记目标已存在时不重建，只把上一轮用例改掉的状态归一化
    /// （领域→学习、状态→进行中），并补齐旧轮次缺失的行2数据（期限/记录/计划），
    /// 保证同一模拟器重跑套件结果确定。
    /// 归一化只在进程内首次执行（列表 .task 在每次视图重出现时都会调本入口，
    /// 若每次都归一化，会把用例本轮刚保存的合法修改打回初始态）。
    /// 已到期无法经 UI 造（期限 DatePicker 不让选过去），走此直写钩子
    private static var listStatesNormalizedInThisProcess = false

    static func seedListStatesIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("UITEST_SEED_GOAL_LIST_STATES") else { return }
        DarkModeManager.shared.currentSetting = .light
        let context = CoreDataStack.shared.viewContext
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", "走查·过程型目标")
        let existing = (try? context.fetch(request))?.first
        if let marker = existing {
            guard !listStatesNormalizedInThisProcess else { return }
            listStatesNormalizedInThisProcess = true
            marker.goalDomain = .learning
            marker.goalStatus = .active
            backfillListStateData(now: Date())
            try? context.save()
            GoalRepository.shared.loadGoals()
            return
        }
        listStatesNormalizedInThisProcess = true
        let now = Date()
        func make(_ title: String, domain: GoalDomain, deadline: Date? = nil) -> Goal {
            Goal.create(in: context, title: title, summary: nil, domain: domain,
                        desiredOutcome: nil, motivation: nil, deadline: deadline, allowAIContext: false)
        }
        let cumulative = make("走查·跑满 300 公里", domain: .health)
        cumulative.goalKindEnum = .cumulative
        cumulative.metricSourceEnum = .manual
        cumulative.metricUnit = "公里"
        cumulative.metricTargetValueDouble = 300
        _ = make("走查·过程型目标", domain: .learning)
        let paused = make("走查·暂停的目标", domain: .life)
        paused.goalStatus = .paused
        let completed = make("走查·完成的目标", domain: .project)
        let overdue = make("走查·已到期的目标", domain: .career,
                 deadline: Calendar.current.date(byAdding: .day, value: -1, to: now))
        completed.goalKindEnum = .cumulative
        completed.metricSourceEnum = .manual
        completed.metricUnit = "公里"
        completed.metricTargetValueDouble = 90
        completed.goalStatus = .completed
        overdue.goalKindEnum = .cumulative
        overdue.metricSourceEnum = .manual
        overdue.metricUnit = "公里"
        overdue.metricTargetValueDouble = 500
        do {
            try context.save()
            backfillListStateData(now: now)
            try context.save()
            HabitRepository.shared.loadActiveHabits()
            GoalRepository.shared.loadGoals()
        } catch { assertionFailure("列表走查种子失败：\(error)") }
    }

    /// 行2 真实数据补齐（R2）：量化卡手动记录（legacy 计划解析会把 manual 源合成
    /// resultSource，卡片读 GoalMetricLog 得「128 / 300 公里」与非零进度）、
    /// 量化卡期限、过程型卡挂 result 绑定习惯（记录天数摘要「5 / 7 天」）。
    /// 全部走「缺才补」，旧轮次已有数据不覆盖
    private static func backfillListStateData(now: Date) {
        let context = CoreDataStack.shared.viewContext
        let calendar = Calendar.current
        func goal(_ title: String) -> Goal? {
            let request = Goal.fetchRequest()
            request.predicate = NSPredicate(format: "title == %@", title)
            return (try? context.fetch(request))?.first
        }
        func addMetricLog(_ goal: Goal, value: Double, daysAgo: Int) {
            let log = GoalMetricLog(context: context)
            log.id = UUID()
            log.goalId = goal.id
            log.value = value
            log.date = calendar.date(byAdding: .hour, value: 10, to: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now)) ?? now
            log.createdAt = log.date
        }
        func hasLogs(_ goal: Goal) -> Bool {
            let request = GoalMetricLog.fetchRequest()
            request.predicate = NSPredicate(format: "goalId == %@ AND deletedAt == nil", goal.id as CVarArg)
            return ((try? context.count(for: request)) ?? 0) > 0
        }
        // 量化卡：期限 + 量化字段 + 非零进度（128 / 300）。
        // manual 源只累计 createdAt 之后的记录，createdAt 需前移到记录之前；
        // 旧轮次种子无量化字段（R2 之前），一并按缺补齐
        func backfillQuantum(_ title: String, deadline: Date?, target: Double, logs: [(Double, Int)]) {
            guard let goal = goal(title) else { return }
            if let deadline, goal.deadline == nil { goal.deadline = deadline }
            if goal.metricTargetValueDouble == nil {
                goal.goalKindEnum = .cumulative
                goal.metricSourceEnum = .manual
                goal.metricUnit = "公里"
                goal.metricTargetValueDouble = target
            }
            guard !hasLogs(goal) else { return }
            if let earliest = calendar.date(byAdding: .day, value: -30, to: now),
               goal.createdAt > earliest {
                goal.createdAt = earliest
            }
            for (value, daysAgo) in logs { addMetricLog(goal, value: value, daysAgo: daysAgo) }
        }
        backfillQuantum("走查·跑满 300 公里",
                        deadline: calendar.date(byAdding: .month, value: 2, to: now),
                        target: 300, logs: [(42, 9), (86, 2)])
        backfillQuantum("走查·完成的目标", deadline: nil, target: 90, logs: [(90, 3)])
        backfillQuantum("走查·已到期的目标", deadline: nil, target: 500, logs: [(60, 6), (70, 5), (50, 4)])
        // 过程型卡：result 绑定数值习惯（7 天窗口记 5 天 → 「走查·每日读书 5 / 7 天」）
        if let process = goal("走查·过程型目标"),
           GoalPlanRevisionStore.latestRevisionRow(goalID: process.id, in: context) == nil {
            let reading = Habit.create(in: context, name: "走查·每日读书", icon: "book", color: "#3B82F6",
                type: .numeric, targetValue: 30, unit: "分钟", isBadHabit: false)
            reading.createdAt = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            for daysAgo in [1, 2, 3, 5, 6] {
                let row = HabitRecord.createNumeric(in: context, habit: reading, value: 30)
                row.date = calendar.date(byAdding: .hour, value: 9, to: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now)) ?? now
                row.createdAt = row.date
            }
            let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: reading.id,
                role: .result, displayTitle: reading.name, isGoalOwned: false,
                requirement: GoalBindingRequirement(metric: .recordedDays, target: 7, windowDays: 7))
            let payload = GoalPlanPayloadV2(schemaVersion: 3,
                intent: GoalPlanIntentV2(originalWish: process.title, successCriteria: nil, deadline: nil),
                resultSource: nil, bindings: [binding],
                basis: GoalPlanDecisionBasisV2(origin: .manual, confirmedAt: now))
            _ = try? GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: process.id,
                sourceSessionID: nil, revisionNumber: 1, baseRevisionID: nil, operationID: UUID(),
                effectiveFrom: calendar.date(byAdding: .day, value: -7, to: now) ?? now, payload: payload, legacySummary: nil)
        }
    }
}
#endif
