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
    private static let dailyTokenBudget = 800

    // MARK: - Build Context

    func build(
        periodType: MemoryInsightPeriodType,
        referenceDate: Date = Date()
    ) async -> (context: MemoryInsightContext, snapshotHash: String) {
        let (start, end) = Self.periodRange(periodType: periodType, referenceDate: referenceDate)

        let (finance, financeAnomalies) = await buildFinanceContext(start: start, end: end, periodType: periodType)
        let (habits, habitAnomalies) = buildHabitContext(start: start, end: end)
        let (tasks, taskAnomalies) = buildTaskContext(start: start, end: end)
        let thoughts = buildThoughtContext(start: start, end: end)
        let milestones = Self.buildMilestoneContext(start: start, end: end)

        let correlations = CrossModuleCorrelator.detect(
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts
        )

        let allAnomalies = Self.deduplicateAnomalies(financeAnomalies + habitAnomalies + taskAnomalies)

        // 上期回顾
        let previousReview = Self.buildPreviousPeriodReview(
            periodType: periodType,
            currentStart: start,
            insightRepo: insightRepo
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
            monthlyInsightDigests: [],
            anomalies: allAnomalies,
            previousPeriodReview: previousReview
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

    /// 智能周期回退：当前周期天数不足阈值时自动回退到上一周期
    /// - Parameters:
    ///   - periodType: 周期类型
    ///   - referenceDate: 参考日期（默认今天）
    ///   - minDays: 最小有效天数（周默认 3 天，月默认 7 天）
    /// - Returns: (start, end, isFallback)
    static func effectivePeriodRange(
        periodType: MemoryInsightPeriodType,
        referenceDate: Date = Date(),
        minDays: Int? = nil
    ) -> (start: Date, end: Date, isFallback: Bool) {
        let threshold = minDays ?? (periodType == .weekly ? 3 : 7)
        let current = periodRange(periodType: periodType, referenceDate: referenceDate)
        let daySpan = Calendar.current.dateComponents([.day], from: current.start, to: current.end).day ?? 0

        if daySpan >= threshold {
            return (current.start, current.end, false)
        }

        let prevRef: Date
        switch periodType {
        case .weekly: prevRef = referenceDate.addingDays(-7)
        case .monthly: prevRef = referenceDate.addingMonths(-1)
        case .daily: prevRef = referenceDate.addingDays(-1)
        }
        let prev = periodRange(periodType: periodType, referenceDate: prevRef)
        return (prev.start, prev.end, true)
    }

    // MARK: - Finance

    private func buildFinanceContext(
        start: Date,
        end: Date,
        periodType: MemoryInsightPeriodType
    ) async -> (context: MemoryInsightFinanceContext, anomalies: [AnomalyObservation]) {
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

        // 结构化异常检测
        var structuredAnomalies: [AnomalyObservation] = []
        var textAnomalies: [String] = []

        let daysInPeriod = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 7
        if daysInPeriod > 0, totalExpense > 0 {
            let dailyAvg = totalExpense / Decimal(daysInPeriod)
            if dailyAvg > 0 {
                // 消费突增：检查每个交易日是否超过均值 2 倍且 > 100
                for day in dailyExpenses {
                    guard day.amount > 100 else { continue }
                    let ratio = (day.amount / dailyAvg as NSDecimalNumber).doubleValue
                    guard ratio >= 2 else { continue }

                    let severity: AnomalySeverity = ratio > 5 ? .critical : .warning
                    let percentDisplay = min(Int((ratio - 1) * 100), 999)
                    structuredAnomalies.append(AnomalyObservation(
                        type: .spendingSpike,
                        severity: severity,
                        scopeKey: "spending:\(day.date)",
                        title: "单日消费突增",
                        summary: "\(day.date) 支出 ¥\(day.amount)，高于均值 \(percentDisplay)%",
                        evidence: ["日均支出 ¥\(dailyAvg)", "当日支出 ¥\(day.amount)"],
                        metricValue: (day.amount as NSDecimalNumber).doubleValue,
                        baselineValue: (dailyAvg as NSDecimalNumber).doubleValue,
                        ratio: ratio
                    ))
                    textAnomalies.append("\(day.date) 单日 ¥\(day.amount)（高于均值 \(percentDisplay)%）")
                }
            }
        }

        // 预算异常
        if let budget = budgetSummary {
            // 总预算超支
            if budget.progressPercent >= 1.0 {
                let progressPercent = Int(budget.progressPercent * 100)
                structuredAnomalies.append(AnomalyObservation(
                    type: .budgetOverrun,
                    severity: .critical,
                    scopeKey: "budget:global",
                    title: "总预算已超支",
                    summary: "总预算使用率 \(progressPercent)%",
                    evidence: ["总预算 ¥\(budget.totalBudget)", "已支出 ¥\(budget.totalSpent)"],
                    metricValue: budget.progressPercent * 100,
                    baselineValue: 100.0,
                    ratio: nil
                ))
            }

            // 分类预算预警
            let categoryWarnings = budgetRepo.getWarningCategoryBudgets(period: budgetPeriod)
            for warning in categoryWarnings {
                let progressPercent = Int(warning.progress * 100)
                let isOverrun = warning.isOverBudget
                structuredAnomalies.append(AnomalyObservation(
                    type: isOverrun ? .budgetOverrun : .budgetWarning,
                    severity: isOverrun ? .critical : .warning,
                    scopeKey: "budget:category:\(warning.categoryId?.uuidString ?? warning.categoryName)",
                    title: isOverrun ? "\(warning.categoryName)预算超支" : "\(warning.categoryName)预算预警",
                    summary: "\(warning.categoryName)使用率 \(progressPercent)%",
                    evidence: ["分类：\(warning.categoryName)", "使用率：\(progressPercent)%"],
                    metricValue: warning.progress * 100,
                    baselineValue: 100.0,
                    ratio: nil
                ))
            }
        }

        // 工作日/周末消费分布
        let weekdayWeekend = Self.computeWeekdayWeekendSpending(
            dailyExpenses: dailyExpenses,
            start: start,
            end: end
        )

        let context = MemoryInsightFinanceContext(
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            topCategories: topCategories,
            dailyExpenses: dailyExpenses,
            previousPeriodExpense: previousPeriodExpense,
            budgetPerformance: budgetSummary,
            anomalyDescriptions: textAnomalies,
            weekdayWeekendSpending: weekdayWeekend
        )
        return (context, structuredAnomalies)
    }

    // MARK: - Habits

    private func buildHabitContext(
        start: Date,
        end: Date
    ) -> (context: MemoryInsightHabitContext, anomalies: [AnomalyObservation]) {
        let range = start...end.addingDays(1)

        let habits = habitRepo.activeHabits
        var completedRecordCount = 0
        var streaks: [HabitStreakSummary] = []

        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: range)
            let completed = records.filter { $0.isCompleted }.count
            completedRecordCount += completed

            let streakInfo = habitRepo.calculateStreakInfo(for: habit)
            if streakInfo.value >= 3 {
                streaks.append(HabitStreakSummary(
                    habitName: habit.name,
                    streakDays: streakInfo.value
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

        // 习惯断连检测：仅限每日、正向、打卡型活跃习惯
        var habitAnomalies: [AnomalyObservation] = []
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = Date()

        for habit in habits {
            guard habit.isCheckInType,
                  !habit.isBadHabit,
                  habit.habitFrequency == .daily else { continue }

            let missedDays = Self.consecutiveMissedDays(
                for: habit,
                upTo: today,
                habitRepo: habitRepo,
                calendar: calendar,
                dateFormatter: dateFormatter
            )

            if missedDays >= 3 {
                habitAnomalies.append(AnomalyObservation(
                    type: .habitBreak,
                    severity: .warning,
                    scopeKey: "habit:\(habit.id.uuidString)",
                    title: "\(habit.name)已断连",
                    summary: "连续 \(missedDays) 天未完成打卡",
                    evidence: ["习惯：\(habit.name)", "连续未完成：\(missedDays) 天"],
                    metricValue: Double(missedDays),
                    baselineValue: 0,
                    ratio: nil
                ))
            }
        }

        let context = MemoryInsightHabitContext(
            activeHabitCount: habits.count,
            completedRecordCount: completedRecordCount,
            previousPeriodCompletedRecordCount: previousPeriodCompletedRecordCount,
            streaks: streaks.sorted { $0.streakDays > $1.streakDays },
            averageCompletionRate: overviewStats.averageCompletionRate,
            topPerformingHabits: topPerforming,
            strugglingHabits: struggling,
            habitCategoryCompletionSummaries: []
        )
        return (context, habitAnomalies)
    }

    // MARK: - Tasks

    private func buildTaskContext(start: Date, end: Date) -> (context: MemoryInsightTaskContext, anomalies: [AnomalyObservation]) {
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

        let totalActive = todoRepo.activeTasks.count

        // 任务堆积检测
        var taskAnomalies: [AnomalyObservation] = []
        if totalActive >= 10 && overdueCount >= 3 {
            let severity: AnomalySeverity = overdueCount > 5 ? .critical : .warning
            taskAnomalies.append(AnomalyObservation(
                type: .taskOverload,
                severity: severity,
                scopeKey: "task:overdue",
                title: "任务堆积",
                summary: "\(totalActive) 个活跃任务中 \(overdueCount) 个已逾期",
                evidence: ["活跃任务：\(totalActive)", "逾期任务：\(overdueCount)"],
                metricValue: Double(overdueCount),
                baselineValue: nil,
                ratio: nil
            ))
        }

        let taskContext = MemoryInsightTaskContext(
            completedCount: completedCount,
            overdueCount: overdueCount,
            importantCompletedTasks: importantCompletedTasks,
            totalCount: totalActive,
            completionRate: stats.completionRate,
            highPriorityCompletionRate: stats.highPriorityCompletionRate,
            dailyCompletionTrend: trend
        )
        return (taskContext, taskAnomalies)
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

        // 情绪摘要
        let sentimentSummary = Self.computeSentimentSummary(
            moodDistribution: moodDist,
            textContents: texts,
            totalCount: totalCount
        )

        return MemoryInsightThoughtContext(
            totalCount: totalCount,
            recentSnippets: recentSnippets,
            textContents: texts,
            moodDistribution: moodDist,
            topTags: tags,
            thoughtSentimentSummary: sentimentSummary
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
        let (finance, _) = await buildFinanceContext(start: yearStart, end: yearEnd, periodType: .monthly)
        let (habits, _) = buildHabitContext(start: yearStart, end: yearEnd)
        let (tasks, _) = buildTaskContext(start: yearStart, end: yearEnd)
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
            monthlyInsightDigests: digests,
            anomalies: [],
            previousPeriodReview: nil
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
                previousPeriodExpense: 0, budgetPerformance: nil, anomalyDescriptions: [],
                weekdayWeekendSpending: nil
            ),
            habits: MemoryInsightHabitContext(
                activeHabitCount: 0, completedRecordCount: 0,
                previousPeriodCompletedRecordCount: 0, streaks: [],
                averageCompletionRate: nil, topPerformingHabits: [], strugglingHabits: [],
                habitCategoryCompletionSummaries: []
            ),
            tasks: MemoryInsightTaskContext(
                completedCount: 0, overdueCount: 0, importantCompletedTasks: [],
                totalCount: 0, completionRate: 0,
                highPriorityCompletionRate: nil, dailyCompletionTrend: []
            ),
            thoughts: MemoryInsightThoughtContext(
                totalCount: 0, recentSnippets: [],
                textContents: [], moodDistribution: [:], topTags: [],
                thoughtSentimentSummary: ThoughtSentimentSummary(negativeRatio: nil, source: "none")
            ),
            milestones: [],
            crossModuleCorrelations: [],
            monthlyInsightDigests: [],
            anomalies: [],
            previousPeriodReview: nil
        )
    }

    private func mapCardTypeToModule(_ cardType: MemoryInsightCardType) -> InsightModule {
        switch cardType {
        case .finance: return .finance
        case .habit: return .habit
        case .task: return .task
        case .thought: return .thought
        case .anomaly: return .finance
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
        let budget: Int
        switch periodType {
        case .daily: budget = dailyTokenBudget
        case .weekly: budget = weeklyTokenBudget
        case .monthly: budget = monthlyTokenBudget
        }

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
                topTags: truncatedThoughts.topTags,
                thoughtSentimentSummary: truncatedThoughts.thoughtSentimentSummary
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
                anomalyDescriptions: truncatedFinance.anomalyDescriptions,
                weekdayWeekendSpending: truncatedFinance.weekdayWeekendSpending
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
            monthlyInsightDigests: context.monthlyInsightDigests,
            anomalies: context.anomalies,
            previousPeriodReview: context.previousPeriodReview
        )
    }

    // MARK: - Snapshot Hash

    static func computeHash(_ context: MemoryInsightContext) -> String {
        guard let encoded = try? JSONEncoder().encode(context) else { return "" }
        let hash = SHA256.hash(data: encoded)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Anomaly Helpers

    /// 按 scopeKey 去重，保留最高严重度
    private static func deduplicateAnomalies(_ anomalies: [AnomalyObservation]) -> [AnomalyObservation] {
        var best: [String: AnomalyObservation] = [:]
        let severityOrder: [AnomalySeverity] = [.info, .warning, .critical]

        for anomaly in anomalies {
            if let existing = best[anomaly.scopeKey] {
                let existingRank = severityOrder.firstIndex(of: existing.severity) ?? 0
                let newRank = severityOrder.firstIndex(of: anomaly.severity) ?? 0
                if newRank > existingRank {
                    best[anomaly.scopeKey] = anomaly
                }
            } else {
                best[anomaly.scopeKey] = anomaly
            }
        }
        return Array(best.values)
    }

    /// 计算连续未打卡天数（从昨天往前数）
    private static func consecutiveMissedDays(
        for habit: Habit,
        upTo date: Date,
        habitRepo: HabitRepository,
        calendar: Calendar,
        dateFormatter: DateFormatter
    ) -> Int {
        guard let checkStart = calendar.date(byAdding: .day, value: -30, to: date) else { return 0 }
        let records = habitRepo.getRecords(for: habit, in: checkStart...date)

        var completedDates = Set<String>()
        for record in records where record.isCompleted {
            completedDates.insert(dateFormatter.string(from: record.date))
        }

        var missedDays = 0
        guard var checkDate = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }

        for _ in 0..<30 {
            let dayStr = dateFormatter.string(from: checkDate)
            if completedDates.contains(dayStr) {
                break
            }
            missedDays += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }
        return missedDays
    }

    /// 计算工作日/周末消费分布
    private static func computeWeekdayWeekendSpending(
        dailyExpenses: [DailyAmountSummary],
        start: Date,
        end: Date
    ) -> WeekdayWeekendSpendingSummary? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let calendar = Calendar.current
        var weekdayExpense: Decimal = 0
        var weekendExpense: Decimal = 0
        var weekdayCount = 0
        var weekendCount = 0

        for day in dailyExpenses {
            guard let date = dateFormatter.date(from: day.date), date >= start else { continue }
            let weekday = calendar.component(.weekday, from: date)
            if weekday == 1 || weekday == 7 { // 周日=1, 周六=7
                weekendExpense += day.amount
                weekendCount += 1
            } else {
                weekdayExpense += day.amount
                weekdayCount += 1
            }
        }

        guard weekdayCount > 0 || weekendCount > 0 else { return nil }
        return WeekdayWeekendSpendingSummary(
            weekdayExpense: weekdayExpense,
            weekendExpense: weekendExpense,
            weekdayTransactionCount: weekdayCount,
            weekendTransactionCount: weekendCount
        )
    }

    /// 计算情绪摘要
    private static func computeSentimentSummary(
        moodDistribution: [String: Int],
        textContents: [String],
        totalCount: Int
    ) -> ThoughtSentimentSummary {
        let negativeMoods = ["悲伤", "焦虑", "愤怒", "压抑", "沮丧", "烦躁", "难过"]
        let totalMoodCount = moodDistribution.values.reduce(0, +)

        if totalMoodCount >= 3 {
            let negativeCount = moodDistribution
                .filter { negativeMoods.contains($0.key) }
                .reduce(0) { $0 + $1.value }
            let ratio = Double(negativeCount) / Double(totalMoodCount)
            return ThoughtSentimentSummary(negativeRatio: ratio, source: "mood")
        }

        if totalCount >= 5, !textContents.isEmpty {
            let negativeKeywords = ["焦虑", "压力", "累", "烦", "难", "沮丧", "崩溃", "无助"]
            let negativeTextCount = textContents.filter { text in
                negativeKeywords.contains { text.contains($0) }
            }.count
            let ratio = Double(negativeTextCount) / Double(textContents.count)
            return ThoughtSentimentSummary(negativeRatio: ratio, source: "text")
        }

        return ThoughtSentimentSummary(negativeRatio: nil, source: "none")
    }

    /// 构建上期回顾
    private static func buildPreviousPeriodReview(
        periodType: MemoryInsightPeriodType,
        currentStart: Date,
        insightRepo: MemoryInsightRepository
    ) -> PreviousPeriodReview? {
        guard let prevInsight = insightRepo.fetchPreviousPeriodInsight(
            periodType: periodType,
            currentStart: currentStart
        ) else {
            return nil
        }

        guard let payload = prevInsight.parsedPayload else { return nil }

        let suggestions = Array(payload.suggestedQuestions.prefix(3))
        let anomalyTitles = payload.cards
            .filter { $0.type == .anomaly }
            .map(\.title)
        let summary = String(payload.summary.prefix(160))

        return PreviousPeriodReview(
            previousSuggestions: suggestions,
            previousAnomalyTitles: anomalyTitles,
            previousSummary: summary.isEmpty ? nil : summary
        )
    }
}
