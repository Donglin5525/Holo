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

        // 结构化 profile snapshot（受 feature flag 控制）
        let profileSnapshot = HoloProfileService.shared.loadSnapshot()

        let transactions = await buildTransactionSummary()
        let habits = buildHabitSummary(profileContext: profileContext)
        let tasks = buildTaskSummary()
        let thoughts = buildThoughtSummary()
        let accounts = buildAccountSummary()

        let recentTrend = await buildRecentTrend()

        let goalContext = buildGoalContext(limit: 3)

        let anniversaryLines = buildAnniversaryLines()

        // 记忆摘要只能经统一 Query Service 读取，开关关闭时返回空。
        let memorySummary: HoloMemoryPromptSummary? =
            HoloAIFeatureFlags.memorySummaryInjectionEnabled
                ? await HoloMemorySummaryProvider.selectRelevantSummary(
                    purpose: .todayState,
                    consumer: .chat
                )
                : nil

        let coverage = DataCoverageEvaluator.evaluate(
            from: UserContext(
                todayDate: todayDate,
                transactions: transactions,
                habits: habits,
                tasks: tasks,
                thoughts: thoughts,
                accounts: accounts,
                profileContext: profileContext.isEmpty ? nil : profileContext,
                profileSnapshot: profileSnapshot,
                recentTrend: recentTrend,
                goalContext: goalContext,
                dataCoverage: nil,
                memorySummary: memorySummary,
                anniversaryLines: anniversaryLines
            )
        )

        return UserContext(
            todayDate: todayDate,
            transactions: transactions,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts,
            accounts: accounts,
            profileContext: profileContext.isEmpty ? nil : profileContext,
            profileSnapshot: profileSnapshot,
            recentTrend: recentTrend,
            goalContext: goalContext,
            dataCoverage: coverage,
            memorySummary: memorySummary,
            anniversaryLines: anniversaryLines
        )
    }

    // MARK: - Transaction Summary

    private func buildTransactionSummary() async -> TransactionSummary {
        do {
            let repo = FinanceRepository.shared
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

            let todayTransactions = try await repo.getStatisticsTransactions(from: today, to: tomorrow)

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

        // 构建今日每个习惯的打卡/数值摘要
        let recentCheckIns = activeHabits.map { habit in
            formatHabitTodayLine(habit: habit, repo: repo)
        }

        // 分正负向统计打卡型习惯
        let split = repo.getTodayCheckInSplit()

        return HabitSummary(
            totalActive: activeHabits.count,
            todayCompleted: split.positive.completed,
            todayTotal: split.positive.total,
            todayNegativeChecked: split.negative.checked,
            todayNegativeTotal: split.negative.total,
            recentCheckIns: recentCheckIns,
            activeHabitNames: habitNames,
            focusSummaries: focusSummaries,
            focusTopicLines: focusTopicLines
        )
    }

    /// 格式化单个习惯今日状态，供 AI 上下文使用
    private func formatHabitTodayLine(habit: Habit, repo: HabitRepository) -> String {
        let name = habit.name

        if habit.isCheckInType {
            let done = repo.isTodayCompleted(for: habit)
            if habit.isBadHabit {
                return "\(name): \(done ? "已发生" : "未发生")"
            } else {
                return "\(name): \(done ? "已打卡" : "未打卡")"
            }
        }

        // 数值型：显示今日聚合值
        if let value = repo.getTodayValue(for: habit) {
            let unit = habit.unitText
            let overTarget = habit.isBadHabit
                && habit.targetValue != nil
                && value > habit.targetValue!.doubleValue
            let suffix = overTarget ? "（超标）" : ""
            let displayValue = habit.isMeasureType
                ? String(format: "%.1f", value)
                : "\(Int(value))"
            return "\(name): \(displayValue)\(unit)\(suffix)"
        }

        return "\(name): 未记录"
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
        let stats = repo.getTodayTaskStats()
        let todayTasks = repo.getTodayTasks()

        // 近期任务列表：优先今日到期，不足时补充未完成积压
        let recentList = buildRecentTaskList(todayTasks: todayTasks, repo: repo)

        // 前 10 条未完成任务摘要（用于积压展示）
        let activeTasks = repo.activeTasks.filter { !$0.completed && !$0.deletedFlag }
        let activeTaskSummaries = activeTasks.prefix(10).map { "○ \($0.title)" }

        return TaskSummary(
            dueToday: stats.dueToday,
            completedToday: stats.completedToday,
            overdueCount: stats.overdue,
            recentTasks: recentList,
            activeTaskSummaries: activeTaskSummaries
        )
    }

    /// 构建近期任务列表：优先今日到期任务，不足 3 条时补充未完成积压
    private func buildRecentTaskList(todayTasks: [TodoTask], repo: TodoRepository) -> [String] {
        var lines: [String] = []

        for task in todayTasks.prefix(5) {
            let status = task.completed ? "✓" : "○"
            lines.append("\(status) \(task.title)")
        }

        // 不足 3 条时补充最近的未完成任务
        if lines.count < 3 {
            let existingTitles = Set(todayTasks.map(\.title))
            let activeTasks = repo.activeTasks
                .filter { !$0.completed && !$0.deletedFlag && !existingTitles.contains($0.title) }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

            for task in activeTasks {
                if lines.count >= 5 { break }
                let dueLabel = formatDueLabel(task.dueDate)
                lines.append("○ \(task.title)（\(dueLabel)）")
            }
        }

        return lines
    }

    /// 格式化截止日期标签
    private func formatDueLabel(_ date: Date?) -> String {
        guard let date = date else { return "无截止日" }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)

        let dayDiff = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        switch dayDiff {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case 3...: return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
        case ..<0: return "逾期\(-dayDiff)天"
        default: return "无截止日"
        }
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
            let transactions = try await repo.getStatisticsTransactions(from: start, to: end)
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
            let deadlineSuffix: String = {
                guard let deadline = goal.deadline else { return "" }
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: deadline)).day ?? 0
                return days >= 0 ? "（还剩 \(days) 天）" : "（已逾期 \(-days) 天）"
            }()
            // 量化目标：注入当前值/目标值/速率/预测结论（紧凑两行），替代过程型任务习惯摘要
            if goal.isQuantitative, let metric = GoalMetricEvaluator.evaluate(goal: goal) {
                var line = """
                - \(goal.title)
                  - 量化目标\(deadlineSuffix)：当前 \(GoalMetricEvaluator.formatValue(metric.currentValue))/\(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))\(goal.metricUnitText)
                  - \(Self.quantitativeForecastText(metric: metric))
                  - 期望结果：\(goal.desiredOutcome ?? "未设定")
                  - 动机：\(goal.motivation ?? "未设定")
                """
                if !goal.proactiveNudge {
                    line += "\n  - 主动提醒：已关闭——不要主动提起此目标，仅在被问到时参考"
                }
                return line
            }
            let progress = GoalProgressEvaluator.evaluate(goal: goal)
            var line = """
            - \(goal.title)
              - 状态：\(progress.state.displayName)\(deadlineSuffix)
              - \(progress.taskSummary)
              - \(progress.habitSummary)
              - 期望结果：\(goal.desiredOutcome ?? "未设定")
              - 动机：\(goal.motivation ?? "未设定")
            """
            if !goal.proactiveNudge {
                line += "\n  - 主动提醒：已关闭——不要主动提起此目标，仅在被问到时参考"
            }
            return line
        }

        return """
        ## 当前目标

        （主动建议规则：对话自然相关时可围绕目标顺势给一句建议；每条回复最多涉及一个目标，语气平实，用户不感兴趣就不再提。标注「主动提醒已关闭」的目标绝不主动提起。）

        \(lines.joined(separator: "\n"))
        """
    }

    /// 量化目标的预测结论行（供 AI 回答「照这个速度能不能达成」类问题）
    private static func quantitativeForecastText(metric: GoalMetricProgress) -> String {
        if metric.isAchieved {
            return "已达成目标"
        }
        guard let forecast = metric.forecast else {
            return "刚起步或记录不足，暂无法预测达成时间"
        }
        let dateText = GoalMetricEvaluator.displayDateFormatter.string(from: forecast.predictedDate)
        if let meets = forecast.meetsDeadline {
            return meets
                ? "按当前节奏预计 \(dateText) 达成，能赶上截止"
                : "按当前节奏预计 \(dateText) 达成，难以在截止前完成"
        }
        return "按当前节奏预计 \(dateText) 达成"
    }

    /// 全量纪念日事实行（倒计时升序；repeatYearly 按年换算下一次，非重复的未来显示倒计时、过去的标已过）。
    /// 全量而非仅临近：纪念日是低频高价值事实，「X 的生日是哪天/还有多久」这类问答需要任意日期可见。
    private func buildAnniversaryLines() -> [String] {
        let repo = AnniversaryRepository.shared
        repo.setup()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"

        let fullFormatter = DateFormatter()
        fullFormatter.locale = Locale(identifier: "zh_CN")
        fullFormatter.dateFormat = "yyyy年M月d日"

        let candidates = repo.activeAnniversaries.compactMap { anniversary -> (days: Int, line: String)? in
            if anniversary.repeatYearly {
                let dateText = "每年\(formatter.string(from: anniversary.date))"
                var comps = calendar.dateComponents([.month, .day], from: anniversary.date)
                comps.year = calendar.component(.year, from: today)
                guard var next = calendar.date(from: comps).map({ calendar.startOfDay(for: $0) }) else { return nil }
                if next < today,
                   let nextYear = calendar.date(byAdding: .year, value: 1, to: next) {
                    next = nextYear
                }
                let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
                let countdown = days == 0 ? "就是今天" : "还有\(days)天"
                return (days, "\(anniversary.title)：\(dateText)（下一次\(fullFormatter.string(from: next))，\(countdown)）")
            }
            let date = calendar.startOfDay(for: anniversary.date)
            let dateText = fullFormatter.string(from: date)
            if date >= today {
                let days = calendar.dateComponents([.day], from: today, to: date).day ?? 0
                let countdown = days == 0 ? "就是今天" : "还有\(days)天"
                return (days, "\(anniversary.title)：\(dateText)（\(countdown)）")
            }
            return (Int.max, "\(anniversary.title)：\(dateText)（已过）")
        }
        return candidates
            .sorted { $0.days < $1.days }
            .map(\.line)
    }
}
