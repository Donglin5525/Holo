//
//  MemoryInsightContextBuilder.swift
//  Holo
//
//  记忆洞察上下文构建器
//  聚合周期级数据快照，供 AI 生成洞察使用
//

import Foundation
import CryptoKit
import CoreData
import os.log

/// 构建记忆洞察所需的周期级数据上下文
struct MemoryInsightContextBuilder {

    // MARK: - Dependencies

    let financeRepo: FinanceRepository
    let habitRepo: HabitRepository
    let todoRepo: TodoRepository
    let thoughtRepo: ThoughtRepository
    let budgetRepo: BudgetRepository
    let insightRepo: MemoryInsightRepository

    // MARK: - Init

    init(
        financeRepo: FinanceRepository = .shared,
        habitRepo: HabitRepository = .shared,
        todoRepo: TodoRepository = .shared,
        thoughtRepo: ThoughtRepository = ThoughtRepository(),
        budgetRepo: BudgetRepository = .shared,
        insightRepo: MemoryInsightRepository = MemoryInsightRepository()
    ) {
        self.financeRepo = financeRepo
        self.habitRepo = habitRepo
        self.todoRepo = todoRepo
        self.thoughtRepo = thoughtRepo
        self.budgetRepo = budgetRepo
        self.insightRepo = insightRepo
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightContextBuilder")

    // MARK: - Token Budgets

    private static let weeklyTokenBudget = 2000
    private static let monthlyTokenBudget = 3500

    // MARK: - Build Context

    func build(
        periodType: MemoryInsightPeriodType,
        referenceDate: Date = Date()
    ) async -> (context: MemoryInsightContext, snapshotHash: String) {
        let (start, end) = Self.periodRange(periodType: periodType, referenceDate: referenceDate)

        let finance = await buildFinanceContext(start: start, end: end, periodType: periodType)
        let habits = buildHabitContext(start: start, end: end)
        let tasks = buildTaskContext(start: start, end: end)
        let thoughts = buildThoughtContext(start: start, end: end)
        let milestones = Self.buildMilestoneContext(start: start, end: end)

        let correlations = CrossModuleCorrelator.detect(
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts
        )

        var context = MemoryInsightContext(
            periodType: periodType,
            periodStart: start,
            periodEnd: end,
            generatedAt: Date(),
            localeIdentifier: Locale.current.identifier,
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts,
            milestones: milestones,
            crossModuleCorrelations: correlations,
            monthlyInsightDigests: []
        )

        context = Self.enforceTokenBudget(context, periodType: periodType)

        let snapshotHash = Self.computeHash(context)
        return (context, snapshotHash)
    }

    // MARK: - Period Range

    static func periodRange(periodType: MemoryInsightPeriodType, referenceDate: Date) -> (start: Date, end: Date) {
        switch periodType {
        case .weekly:
            let start = referenceDate.startOfWeek
            let end = min(start.addingDays(6), referenceDate)
            return (start.startOfDay, end.startOfDay)
        case .monthly:
            let start = referenceDate.startOfMonth
            let end = min(start.addingDays(referenceDate.daysInMonth - 1), referenceDate)
            return (start.startOfDay, end.startOfDay)
        case .daily:
            let start = referenceDate.startOfDay
            return (start, start)
        }
    }

    // MARK: - Finance

    private func buildFinanceContext(
        start: Date,
        end: Date,
        periodType: MemoryInsightPeriodType
    ) async -> MemoryInsightFinanceContext {
        var totalExpense: Decimal = 0
        var totalIncome: Decimal = 0
        var topCategories: [CategoryAmountSummary] = []
        var dailyExpenses: [DailyAmountSummary] = []
        var previousPeriodExpense: Decimal = 0

        let endDate = end.addingDays(1)

        do {
            let transactions = try await financeRepo.getTransactions(from: start, to: endDate)
            for t in transactions {
                if t.type == "expense" {
                    totalExpense += (t.amount as NSDecimalNumber).decimalValue
                } else {
                    totalIncome += (t.amount as NSDecimalNumber).decimalValue
                }
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            var dailyMap: [String: Decimal] = [:]
            for t in transactions where t.type == "expense" {
                let key = dateFormatter.string(from: t.date)
                dailyMap[key, default: 0] += (t.amount as NSDecimalNumber).decimalValue
            }
            dailyExpenses = dailyMap.map { DailyAmountSummary(date: $0.key, amount: $0.value) }
                .sorted { $0.date < $1.date }

            let aggregations = try await financeRepo.getCategoryAggregations(
                from: start, to: endDate, type: .expense
            )
            topCategories = aggregations.prefix(5).map {
                CategoryAmountSummary(
                    categoryName: $0.category.name,
                    amount: $0.amount
                )
            }
        } catch {
            Self.logger.error("构建财务上下文失败：\(error.localizedDescription)")
        }

        // 上期对比
        let periodLength = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        let prevStart = start.addingDays(-periodLength - 1)
        let prevEnd = start.addingDays(-1)
        do {
            let prevTransactions = try await financeRepo.getTransactions(from: prevStart, to: prevEnd)
            for t in prevTransactions where t.type == "expense" {
                previousPeriodExpense += (t.amount as NSDecimalNumber).decimalValue
            }
        } catch {
            Self.logger.error("构建上期财务数据失败：\(error.localizedDescription)")
        }

        // 预算表现
        let budgetPeriod: BudgetPeriod = periodType == .weekly ? .week : .month
        let budgetSummary: BudgetPerformanceSummary? = {
            guard let budget = budgetRepo.computeGlobalTotalBudgetStatus(period: budgetPeriod) else { return nil }
            let warnings = budgetRepo.getWarningCategoryBudgets(period: budgetPeriod).map(\.categoryName)
            return BudgetPerformanceSummary(
                totalBudget: budget.totalBudgetAmount,
                totalSpent: budget.totalSpentAmount,
                progressPercent: budget.progress,
                isOnTrack: !budget.isOverBudget && !budget.isWarning,
                warningCategories: warnings
            )
        }()

        // 异常检测
        var anomalies: [String] = []
        let daysInPeriod = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        if daysInPeriod > 0, totalExpense > 0 {
            let dailyAvg = totalExpense / Decimal(daysInPeriod)
            if dailyAvg > 0,
               let maxDay = dailyExpenses.max(by: { $0.amount < $1.amount }),
               maxDay.amount > dailyAvg * 3 && maxDay.amount > 100 {
                let ratio = (maxDay.amount / dailyAvg as NSDecimalNumber).doubleValue
                let percentDisplay = min(Int((ratio - 1) * 100), 999)
                anomalies.append("\(maxDay.date) 单日 \(maxDay.amount)（高于均值 \(percentDisplay)%）")
            }
        }

        return MemoryInsightFinanceContext(
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            topCategories: topCategories,
            dailyExpenses: dailyExpenses,
            previousPeriodExpense: previousPeriodExpense,
            budgetPerformance: budgetSummary,
            anomalyDescriptions: anomalies
        )
    }

    // MARK: - Habits

    private func buildHabitContext(
        start: Date,
        end: Date
    ) -> MemoryInsightHabitContext {
        let range = start...end.addingDays(1)

        let habits = habitRepo.activeHabits
        var completedRecordCount = 0
        var streaks: [HabitStreakSummary] = []

        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: range)
            let completed = records.filter { $0.isCompleted }.count
            completedRecordCount += completed

            let streak = habitRepo.calculateStreak(for: habit)
            if streak >= 3 {
                streaks.append(HabitStreakSummary(
                    habitName: habit.name,
                    streakDays: streak
                ))
            }
        }

        // 上期对比
        let periodLength = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        let prevStart = start.addingDays(-periodLength - 1)
        let prevEnd = start.addingDays(-1)
        var previousPeriodCompletedRecordCount = 0
        let prevRange = prevStart...prevEnd
        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: prevRange)
            previousPeriodCompletedRecordCount += records.filter { $0.isCompleted }.count
        }

        // 总览统计 + 排名
        let statsRange: HabitStatsDateRange = periodLength <= 7 ? .week : .month
        let overviewStats = habitRepo.getOverviewStats(range: statsRange)
        let ranking = habitRepo.getHabitRanking(range: statsRange, limit: 10)

        let topPerforming = ranking.prefix(3).map(\.name)
        let struggling = ranking.suffix(3).filter { $0.completionRate < 0.5 }.map(\.name)

        return MemoryInsightHabitContext(
            activeHabitCount: habits.count,
            completedRecordCount: completedRecordCount,
            previousPeriodCompletedRecordCount: previousPeriodCompletedRecordCount,
            streaks: streaks.sorted { $0.streakDays > $1.streakDays },
            averageCompletionRate: overviewStats.averageCompletionRate,
            topPerformingHabits: topPerforming,
            strugglingHabits: struggling
        )
    }

    // MARK: - Tasks

    private func buildTaskContext(start: Date, end: Date) -> MemoryInsightTaskContext {
        let context = CoreDataStack.shared.viewContext

        var completedCount = 0
        var overdueCount = 0
        var importantCompletedTasks: [String] = []

        do {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(
                format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                end.addingDays(1) as CVarArg
            )
            let completedTasks = try context.fetch(request)
            completedCount = completedTasks.count

            importantCompletedTasks = completedTasks
                .filter { $0.priority >= 2 }
                .map { $0.title }
                .prefix(5)
                .map { String($0) }

            let overdue = todoRepo.getOverdueTasks()
            overdueCount = overdue.count
        } catch {
            Self.logger.error("构建任务上下文失败：\(error.localizedDescription)")
        }

        let stats = todoRepo.getCompletionStats(from: start, to: end)
        let trend = todoRepo.getCompletionTrend(from: start, to: end)

        return MemoryInsightTaskContext(
            completedCount: completedCount,
            overdueCount: overdueCount,
            importantCompletedTasks: importantCompletedTasks,
            totalCount: todoRepo.activeTasks.count,
            completionRate: stats.completionRate,
            highPriorityCompletionRate: stats.highPriorityCompletionRate,
            dailyCompletionTrend: trend
        )
    }

    // MARK: - Thoughts

    private func buildThoughtContext(start: Date, end: Date) -> MemoryInsightThoughtContext {
        let endDate = end.addingDays(1)
        var totalCount = 0
        var recentSnippets: [String] = []

        do {
            let filters = ThoughtFilters(startDate: start, endDate: endDate)
            let thoughts = try thoughtRepo.search(query: "", filters: filters)
            totalCount = thoughts.count
            recentSnippets = thoughts
                .prefix(5)
                .map { String($0.content.prefix(50)) }
        } catch {
            Self.logger.error("构建观点上下文失败：\(error.localizedDescription)")
        }

        let moodDist = thoughtRepo.getMoodDistribution(from: start, to: endDate)
        let tags = thoughtRepo.getTopTags(from: start, to: endDate, limit: 3).map(\.name)
        let texts = thoughtRepo.getThoughtTexts(from: start, to: endDate, limit: 20)

        return MemoryInsightThoughtContext(
            totalCount: totalCount,
            recentSnippets: recentSnippets,
            textContents: texts,
            moodDistribution: moodDist,
            topTags: tags
        )
    }

    // MARK: - Annual Review

    func buildAnnualContext(year: Int) async -> MemoryInsightContext {
        let calendar = Calendar.current
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return emptyAnnualContext(year: year)
        }

        // 1. 获取该年所有月度洞察
        let monthlyInsights = insightRepo.fetchMonthlyInsights(for: year)

        // 2. 提取月度摘要
        let digests: [MonthlyInsightDigest] = monthlyInsights.compactMap { insight in
            let cardsJSON = insight.cardsJSON
            guard !cardsJSON.isEmpty,
                  let data = cardsJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(MemoryInsightPayload.self, from: data) else {
                return MonthlyInsightDigest(
                    periodStart: insight.periodStart ?? Date(),
                    periodEnd: insight.periodEnd ?? Date(),
                    summary: insight.summary,
                    keyFindings: [],
                    moduleSnapshots: []
                )
            }
            return MonthlyInsightDigest(
                periodStart: insight.periodStart ?? Date(),
                periodEnd: insight.periodEnd ?? Date(),
                summary: payload.summary,
                keyFindings: payload.cards.prefix(3).map(\.title),
                moduleSnapshots: payload.cards.map { card in
                    ModuleSnapshot(
                        module: mapCardTypeToModule(card.type),
                        headline: "\(card.title): \(card.body.prefix(30))"
                    )
                }
            )
        }

        // 3. 年度原始汇总（复用各 build 方法）
        let finance = await buildFinanceContext(start: yearStart, end: yearEnd, periodType: .monthly)
        let habits = buildHabitContext(start: yearStart, end: yearEnd)
        let tasks = buildTaskContext(start: yearStart, end: yearEnd)
        let thoughts = buildThoughtContext(start: yearStart, end: yearEnd)
        let milestones = Self.buildMilestoneContext(start: yearStart, end: yearEnd)

        let correlations = CrossModuleCorrelator.detect(
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts
        )

        return MemoryInsightContext(
            periodType: .monthly,
            periodStart: yearStart,
            periodEnd: yearEnd,
            generatedAt: Date(),
            localeIdentifier: Locale.current.identifier,
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts,
            milestones: milestones,
            crossModuleCorrelations: correlations,
            monthlyInsightDigests: digests
        )
    }

    private func emptyAnnualContext(year: Int) -> MemoryInsightContext {
        let now = Date()
        return MemoryInsightContext(
            periodType: .monthly,
            periodStart: now,
            periodEnd: now,
            generatedAt: now,
            localeIdentifier: Locale.current.identifier,
            finance: MemoryInsightFinanceContext(
                totalExpense: 0, totalIncome: 0, topCategories: [], dailyExpenses: [],
                previousPeriodExpense: 0, budgetPerformance: nil, anomalyDescriptions: []
            ),
            habits: MemoryInsightHabitContext(
                activeHabitCount: 0, completedRecordCount: 0,
                previousPeriodCompletedRecordCount: 0, streaks: [],
                averageCompletionRate: nil, topPerformingHabits: [], strugglingHabits: []
            ),
            tasks: MemoryInsightTaskContext(
                completedCount: 0, overdueCount: 0, importantCompletedTasks: [],
                totalCount: 0, completionRate: 0,
                highPriorityCompletionRate: nil, dailyCompletionTrend: []
            ),
            thoughts: MemoryInsightThoughtContext(
                totalCount: 0, recentSnippets: [],
                textContents: [], moodDistribution: [:], topTags: []
            ),
            milestones: [],
            crossModuleCorrelations: [],
            monthlyInsightDigests: []
        )
    }

    private func mapCardTypeToModule(_ cardType: MemoryInsightCardType) -> InsightModule {
        switch cardType {
        case .finance: return .finance
        case .habit: return .habit
        case .task: return .task
        case .thought: return .thought
        default: return .finance
        }
    }

    // MARK: - Milestones

    private static func buildMilestoneContext(start: Date, end: Date) -> [MemoryInsightMilestoneContext] {
        let context = CoreDataStack.shared.viewContext
        let allMilestones = MilestoneDetector.detect(context: context)

        return allMilestones
            .filter { $0.date >= start && $0.date <= end.addingDays(1) }
            .map { MemoryInsightMilestoneContext(
                title: $0.data.title,
                description: $0.data.description,
                date: $0.date
            )
        }
    }

    // MARK: - Token Budget

    private static func enforceTokenBudget(
        _ context: MemoryInsightContext,
        periodType: MemoryInsightPeriodType
    ) -> MemoryInsightContext {
        let budget = periodType == .monthly ? monthlyTokenBudget : weeklyTokenBudget

        guard let encoded = try? JSONEncoder().encode(context),
              let _ = String(data: encoded, encoding: .utf8) else {
            return context
        }

        let estimatedTokens = encoded.count / 2

        if estimatedTokens <= budget {
            return context
        }

        // 截断：优先减少 textContents
        var truncatedThoughts = context.thoughts
        if truncatedThoughts.textContents.count > 5 {
            truncatedThoughts = MemoryInsightThoughtContext(
                totalCount: truncatedThoughts.totalCount,
                recentSnippets: truncatedThoughts.recentSnippets,
                textContents: Array(truncatedThoughts.textContents.prefix(5)),
                moodDistribution: truncatedThoughts.moodDistribution,
                topTags: truncatedThoughts.topTags
            )
        }

        // 截断 dailyExpenses
        var truncatedFinance = context.finance
        if truncatedFinance.dailyExpenses.count > 14 {
            truncatedFinance = MemoryInsightFinanceContext(
                totalExpense: truncatedFinance.totalExpense,
                totalIncome: truncatedFinance.totalIncome,
                topCategories: truncatedFinance.topCategories,
                dailyExpenses: Array(truncatedFinance.dailyExpenses.suffix(14)),
                previousPeriodExpense: truncatedFinance.previousPeriodExpense,
                budgetPerformance: truncatedFinance.budgetPerformance,
                anomalyDescriptions: truncatedFinance.anomalyDescriptions
            )
        }

        // 截断 dailyCompletionTrend
        var truncatedTasks = context.tasks
        if truncatedTasks.dailyCompletionTrend.count > 14 {
            truncatedTasks = MemoryInsightTaskContext(
                completedCount: truncatedTasks.completedCount,
                overdueCount: truncatedTasks.overdueCount,
                importantCompletedTasks: truncatedTasks.importantCompletedTasks,
                totalCount: truncatedTasks.totalCount,
                completionRate: truncatedTasks.completionRate,
                highPriorityCompletionRate: truncatedTasks.highPriorityCompletionRate,
                dailyCompletionTrend: Array(truncatedTasks.dailyCompletionTrend.suffix(14))
            )
        }

        return MemoryInsightContext(
            periodType: context.periodType,
            periodStart: context.periodStart,
            periodEnd: context.periodEnd,
            generatedAt: context.generatedAt,
            localeIdentifier: context.localeIdentifier,
            finance: truncatedFinance,
            habits: context.habits,
            tasks: truncatedTasks,
            thoughts: truncatedThoughts,
            milestones: context.milestones,
            crossModuleCorrelations: context.crossModuleCorrelations,
            monthlyInsightDigests: context.monthlyInsightDigests
        )
    }

    // MARK: - Snapshot Hash

    static func computeHash(_ context: MemoryInsightContext) -> String {
        guard let encoded = try? JSONEncoder().encode(context) else { return "" }
        let hash = SHA256.hash(data: encoded)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
