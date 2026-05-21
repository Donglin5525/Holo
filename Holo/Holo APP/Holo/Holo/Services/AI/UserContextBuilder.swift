//
//  UserContextBuilder.swift
//  Holo
//
//  用户上下文构建器
//  从各 Repository 收集数据，构建 AI 所需的 UserContext
//

import Foundation
import os.log

@MainActor
final class UserContextBuilder {

    static let shared = UserContextBuilder()

    private let logger = Logger(subsystem: "com.holo.app", category: "UserContextBuilder")

    private init() {}

    /// 构建当前用户上下文
    func buildContext() async -> UserContext {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
        let todayDate = dateFormatter.string(from: Date())

        let profileContext = HoloProfileService.shared.loadProfile()

        let transactions = await buildTransactionSummary()
        let habits = buildHabitSummary(profileContext: profileContext)
        let tasks = buildTaskSummary()
        let thoughts = buildThoughtSummary()
        let accounts = buildAccountSummary()

        let recentTrend = await buildRecentTrend()

        let goalContext = buildGoalContext(limit: 1)

        return UserContext(
            todayDate: todayDate,
            transactions: transactions,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts,
            accounts: accounts,
            profileContext: profileContext.isEmpty ? nil : profileContext,
            recentTrend: recentTrend,
            goalContext: goalContext
        )
    }

    // MARK: - Transaction Summary

    private func buildTransactionSummary() async -> TransactionSummary {
        do {
            let repo = FinanceRepository.shared
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

            let todayTransactions = try await repo.getTransactions(from: today, to: tomorrow)

            var todayExpense: Decimal = 0
            var todayIncome: Decimal = 0
            var recentList: [String] = []

            for t in todayTransactions {
                if t.type == "expense" {
                    todayExpense += t.amount as Decimal
                } else {
                    todayIncome += t.amount as Decimal
                }
                recentList.append("\(t.note ?? t.category?.name ?? "未分类") ¥\(t.amount)")
            }

            return TransactionSummary(
                todayExpense: "¥\(todayExpense)",
                todayIncome: "¥\(todayIncome)",
                recentTransactions: Array(recentList.prefix(5))
            )
        } catch {
            logger.warning("构建交易摘要失败：\(error.localizedDescription)")
            return TransactionSummary(todayExpense: "未知", todayIncome: "未知", recentTransactions: [])
        }
    }

    // MARK: - Habit Summary

    private func buildHabitSummary(profileContext: String) -> HabitSummary {
        let repo = HabitRepository.shared
        let progress = repo.getTodayCheckInProgress()

        var recentCheckIns: [String] = []
        // 通过 activeHabits 获取习惯列表
        let activeHabits = repo.activeHabits.filter { !$0.isArchived }

        let habitNames = activeHabits.map { $0.name }
        let focusSummaries = buildHabitFocusSummaries(
            activeHabits: activeHabits,
            profileContext: profileContext,
            repo: repo
        )
        let focusTopicLines = buildFocusTopicLines(
            activeHabits: activeHabits,
            profileContext: profileContext
        )

        return HabitSummary(
            totalActive: activeHabits.count,
            todayCompleted: progress.completed,
            todayTotal: progress.total,
            recentCheckIns: recentCheckIns,
            activeHabitNames: habitNames,
            focusSummaries: focusSummaries,
            focusTopicLines: focusTopicLines
        )
    }

    private func buildHabitFocusSummaries(
        activeHabits: [Habit],
        profileContext: String,
        repo: HabitRepository
    ) -> [HabitFocusSummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
              let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: today) else {
            return []
        }

        return activeHabits.compactMap { habit in
            let goalTitle = habit.goal?.title
            let signal = HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: goalTitle,
                profileContext: profileContext
            )
            guard signal.polarity == .negative || signal.needsClarification else {
                return nil
            }

            let current = repo.evaluatePerformance(for: habit, in: weekAgo...tomorrow)
            let previous = repo.evaluatePerformance(for: habit, in: twoWeeksAgo...weekAgo)
            let streak = repo.calculateStreakInfo(for: habit).value

            return HabitFocusSummary(
                habitName: habit.name,
                signal: signal,
                current: current,
                previous: previous,
                currentStreak: streak,
                goalTitle: goalTitle
            )
        }
    }

    private func buildFocusTopicLines(
        activeHabits: [Habit],
        profileContext: String
    ) -> [String] {
        var lines: [String] = []

        let goals = GoalRepository.shared.activeGoalsForAI(limit: 3)
        for goal in goals {
            let signal = HabitFocusSignal.classify(
                habitName: "",
                isBadHabit: false,
                goalTitle: goal.title,
                profileContext: profileContext
            )
            if signal.polarity == .negative {
                lines.append("目标「\(goal.title)」属于减少/戒除型主题，分析时看发生量下降、超标减少、控制率提升")
            }
        }

        let hasNegativeHabitSignal = activeHabits.contains { habit in
            HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: habit.goal?.title,
                profileContext: profileContext
            ).polarity == .negative
        }
        let profileSignal = HabitFocusSignal.classify(
            habitName: "",
            isBadHabit: false,
            goalTitle: nil,
            profileContext: profileContext
        )
        if profileSignal.sources.contains(.profileKeyword), !hasNegativeHabitSignal {
            lines.append("用户档案出现戒除/减少型主题；如果相关习惯未标记为坏习惯，回答时先确认再按负向趋势分析")
        }

        return Array(lines.prefix(3))
    }

    // MARK: - Task Summary

    private func buildTaskSummary() -> TaskSummary {
        let repo = TodoRepository.shared
        let stats = repo.getTaskStatistics()
        let todayTasks = repo.getTodayTasks()

        var recentList: [String] = []
        for task in todayTasks.prefix(5) {
            let status = task.completed ? "✓" : "○"
            recentList.append("\(status) \(task.title)")
        }

        // 前 10 条未完成任务摘要
        let activeTasks = repo.activeTasks.filter { !$0.completed && !$0.deletedFlag }
        let activeTaskSummaries = activeTasks.prefix(10).map { "○ \($0.title)" }

        return TaskSummary(
            todayTotal: stats.total,
            todayCompleted: stats.completed,
            overdueCount: stats.overdue,
            recentTasks: recentList,
            activeTaskSummaries: activeTaskSummaries
        )
    }

    // MARK: - Thought Summary

    private func buildThoughtSummary() -> ThoughtSummary {
        do {
            let repo = ThoughtRepository()
            let thoughts = try repo.fetchAll(limit: 5)

            var recentList: [String] = []
            for thought in thoughts {
                let prefix = String(thought.content.prefix(30))
                recentList.append(prefix)
            }

            let allThoughts = try repo.fetchAll()
            return ThoughtSummary(
                recentThoughts: recentList,
                totalThoughts: allThoughts.count
            )
        } catch {
            logger.warning("构建观点摘要失败：\(error.localizedDescription)")
            return ThoughtSummary(recentThoughts: [], totalThoughts: 0)
        }
    }

    // MARK: - Account Summary

    private func buildAccountSummary() -> AccountSummary {
        let repo = FinanceRepository.shared
        let accounts = repo.getAccounts(includeArchived: false)
        let defaultAccount = repo.getDefaultAccountSync()

        let list = accounts.map { account in
            let suffix = account.isDefault ? "(默认)" : ""
            return "\(account.name)\(suffix)"
        }.joined(separator: "、")

        return AccountSummary(
            accountList: list,
            defaultAccountName: defaultAccount?.name ?? "默认账户"
        )
    }

    // MARK: - Recent Trend

    private func buildRecentTrend() async -> UserRecentTrend? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
              let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: weekAgo) else {
            return nil
        }

        // 本周收支
        let weekExpense = await calculateExpense(from: weekAgo, to: today)
        // 上周收支（同期）
        let lastWeekExpense = await calculateExpense(from: twoWeeksAgo, to: weekAgo)

        // 环比变化
        let weekExpenseChange = calculateChangeRate(current: weekExpense, previous: lastWeekExpense)

        // 习惯完成率
        let habitRepo = HabitRepository.shared
        let habitStats = habitRepo.getOverviewStats(range: .week)
        let habitRate = habitStats.totalHabits > 0
            ? "\(Int(habitStats.averageCompletionRate))%"
            : nil

        // 任务完成数
        let todoRepo = TodoRepository.shared
        let taskStats = todoRepo.getCompletionStats(from: weekAgo, to: today)

        // Top 支出分类
        let topCategory = await fetchTopExpenseCategory(from: weekAgo, to: today)

        // 今日洞察
        let dailyInsight = fetchDailyInsightSummary()

        return UserRecentTrend(
            weekExpenseTotal: weekExpense > 0 ? "¥\(weekExpense)" : nil ?? "¥0",
            weekExpenseChange: weekExpenseChange,
            weekHabitCompletionRate: habitRate,
            weekTaskCompletedCount: taskStats.completedInPeriod,
            topExpenseCategory: topCategory,
            dailyInsightSummary: dailyInsight
        )
    }

    private func calculateExpense(from start: Date, to end: Date) async -> Decimal {
        do {
            let repo = FinanceRepository.shared
            let transactions = try await repo.getTransactions(from: start, to: end)
            var total: Decimal = 0
            for t in transactions where t.type == "expense" {
                total += t.amount as Decimal
            }
            return total
        } catch {
            logger.warning("计算周期支出失败：\(error.localizedDescription)")
            return 0
        }
    }

    private func calculateChangeRate(current: Decimal, previous: Decimal) -> String? {
        guard previous > 0 else { return current > 0 ? "+100%" : nil }
        let change = (current - previous) / previous * 100
        let percent = Int(truncating: NSDecimalNumber(decimal: change))
        guard abs(percent) >= 5 else { return nil }
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private func fetchTopExpenseCategory(from start: Date, to end: Date) async -> String? {
        do {
            let repo = FinanceRepository.shared
            let aggregations = try await repo.getCategoryAggregations(
                from: start, to: end, type: .expense
            )
            return aggregations.first?.category.name
        } catch {
            return nil
        }
    }

    private func fetchDailyInsightSummary() -> String? {
        do {
            let repo = MemoryInsightRepository()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            let insight = try repo.fetchInsight(periodType: .daily, start: today, end: tomorrow)
            return insight?.title
        } catch {
            return nil
        }
    }

    // MARK: - Goal Context

    private func buildGoalContext(limit: Int) -> String? {
        let goals = GoalRepository.shared.activeGoalsForAI(limit: limit)
        guard !goals.isEmpty else { return nil }

        let lines = goals.map { goal -> String in
            let progress = GoalProgressEvaluator.evaluate(goal: goal)
            return """
            - \(goal.title)
              - 状态：\(progress.state.displayName)
              - \(progress.taskSummary)
              - \(progress.habitSummary)
              - 说明：\(goal.summary ?? goal.desiredOutcome ?? "无")
            """
        }

        return "## 当前目标\n\n" + lines.joined(separator: "\n")
    }
}
