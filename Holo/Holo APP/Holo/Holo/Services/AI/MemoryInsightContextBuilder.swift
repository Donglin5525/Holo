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
@MainActor
struct MemoryInsightContextBuilder {

    // MARK: - Dependencies

    let financeRepo: FinanceRepository
    let habitRepo: HabitRepository
    let todoRepo: TodoRepository
    let thoughtRepo: ThoughtRepository
    let budgetRepo: BudgetRepository
    let insightRepo: MemoryInsightRepository

    /// Core Data 上下文，用于直接访问（非 repo 管理的查询）
    /// 传入后台 context 可让重型读取操作不阻塞主线程
    let dataContext: NSManagedObjectContext

    // MARK: - Init

    init(
        financeRepo: FinanceRepository = .shared,
        habitRepo: HabitRepository = .shared,
        todoRepo: TodoRepository = .shared,
        thoughtRepo: ThoughtRepository = ThoughtRepository(),
        budgetRepo: BudgetRepository = .shared,
        insightRepo: MemoryInsightRepository = MemoryInsightRepository(),
        dataContext: NSManagedObjectContext = CoreDataStack.shared.viewContext
    ) {
        self.financeRepo = financeRepo
        self.habitRepo = habitRepo
        self.todoRepo = todoRepo
        self.thoughtRepo = thoughtRepo
        self.budgetRepo = budgetRepo
        self.insightRepo = insightRepo
        self.dataContext = dataContext
    }

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightContextBuilder")

    // MARK: - Token Budgets

    private static let dailyTokenBudget = 800
    private static let weeklyTokenBudget = 2200
    private static let monthlyTokenBudget = 3800
    private static let annualTokenBudget = 5000

    // MARK: - Build Context

    func build(
        periodType: MemoryInsightPeriodType,
        referenceDate: Date = Date()
    ) async -> (context: MemoryInsightContext, snapshotHash: String) {
        let (start, end) = Self.periodRange(periodType: periodType, referenceDate: referenceDate)
        return await build(periodType: periodType, start: start, end: end)
    }

    func build(
        periodType: MemoryInsightPeriodType,
        start: Date,
        end: Date
    ) async -> (context: MemoryInsightContext, snapshotHash: String) {
        let (finance, financeAnomalies) = await buildFinanceContext(start: start, end: end, periodType: periodType)
        let (habits, habitAnomalies) = buildHabitContext(start: start, end: end)
        let (tasks, taskAnomalies) = buildTaskContext(start: start, end: end)
        let thoughts = buildThoughtContext(start: start, end: end)
        let milestones = buildMilestoneContext(start: start, end: end)

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

        // 生活轨迹上下文
        async let dailySnapshotsTask = buildDailySnapshots(start: start, end: end)
        async let lifeEventsTask = buildLifeEvents(start: start, end: end)
        let personalBaseline = await buildPersonalBaseline(observationStart: start)
        let personalProfileContext = await buildPersonalProfileContext()
        let (dailySnapshots, lifeEvents) = await (dailySnapshotsTask, lifeEventsTask)

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
            previousPeriodReview: previousReview,
            dailySnapshots: dailySnapshots,
            lifeEvents: lifeEvents,
            personalBaseline: personalBaseline,
            personalProfileContext: personalProfileContext
        )

        context = Self.enforceTokenBudget(context, periodType: periodType)

        let snapshotHash = Self.computeHash(context)
        return (context, snapshotHash)
    }

    private func buildPersonalProfileContext() async -> String? {
        await MainActor.run {
            let profile = HoloProfileService.shared.loadProfile()
            return profile.isEmpty ? nil : profile
        }
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
        case .quarterly:
            let start = referenceDate.startOfQuarter
            let fullQuarterEnd = start.addingMonths(3).addingDays(-1)
            let end = min(fullQuarterEnd, referenceDate)
            return (start.startOfDay, end.startOfDay)
        case .custom:
            let start = referenceDate.startOfDay
            return (start, start)
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
        case .quarterly: prevRef = referenceDate.addingMonths(-3)
        case .custom: prevRef = referenceDate.addingDays(-1)
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
        var semanticSummary: FinanceSemanticSummary?

        let endDate = end.addingDays(1)

        do {
            let transactions = try await financeRepo.getTransactions(from: start, to: endDate)
            let expenses = transactions.filter { $0.type == "expense" }
            let incomes = transactions.filter { $0.type == "income" }
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

            let topLevelCategories = try await financeRepo.getTopLevelCategories(by: .expense)
            let topLevelNameMap = Dictionary(
                uniqueKeysWithValues: topLevelCategories.map { ($0.id, $0.name) }
            )
            let dayCount = max(Calendar.current.dateComponents([.day], from: start, to: endDate).day ?? 1, 1)
            semanticSummary = Self.buildFinanceSemanticSummary(
                expenses: expenses,
                incomes: incomes,
                topLevelNameMap: topLevelNameMap,
                dayCount: dayCount
            )
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
            weekdayWeekendSpending: weekdayWeekend,
            semanticSummary: semanticSummary
        )
        return (context, structuredAnomalies)
    }

    private static func buildFinanceSemanticSummary(
        expenses: [Transaction],
        incomes: [Transaction],
        topLevelNameMap: [UUID: String],
        dayCount: Int
    ) -> FinanceSemanticSummary {
        var fixedMap: [String: Decimal] = [:]
        var fixedTotal: Decimal = 0
        var transportTransactions: [Transaction] = []

        for tx in expenses {
            guard let category = tx.category else { continue }
            let parentName = parentCategoryName(for: category, topLevelNameMap: topLevelNameMap)
            if isFixedNecessaryExpense(categoryName: category.name, parentName: parentName) {
                fixedMap[category.name, default: 0] += tx.amount.decimalValue
                fixedTotal += tx.amount.decimalValue
            }
            if isTransportExpense(categoryName: category.name, parentName: parentName) {
                transportTransactions.append(tx)
            }
        }

        let totalExpense = expenses.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        let fixedCategories = fixedMap
            .sorted { $0.value > $1.value }
            .map { name, amount in
                let percentage = totalExpense > 0
                    ? Double(truncating: (amount / totalExpense * 100) as NSDecimalNumber)
                    : 0
                return FinanceCategoryItem(categoryName: name, amount: amount, percentage: percentage)
            }

        return FinanceSemanticSummary(
            fixedNecessaryExpenseTotal: fixedTotal,
            actionableExpenseTotal: max(totalExpense - fixedTotal, 0),
            fixedNecessaryCategories: fixedCategories,
            transport: buildTransportSummary(transactions: transportTransactions),
            incomeCadenceHint: buildIncomeCadenceHint(incomes: incomes, dayCount: dayCount)
        )
    }

    private static func buildTransportSummary(transactions: [Transaction]) -> TransportSpendingSummary? {
        guard !transactions.isEmpty else { return nil }

        var taxiAmount: Decimal = 0
        var taxiCount = 0
        var publicTransitAmount: Decimal = 0
        var publicTransitCount = 0
        var longDistanceAmount: Decimal = 0
        var longDistanceCount = 0
        var totalAmount: Decimal = 0

        for tx in transactions {
            guard let category = tx.category else { continue }
            let amount = tx.amount.decimalValue
            totalAmount += amount
            switch category.name {
            case "打车":
                taxiAmount += amount
                taxiCount += 1
            case "地铁", "公交", "单车":
                publicTransitAmount += amount
                publicTransitCount += 1
            case "火车", "机票", "旅行":
                longDistanceAmount += amount
                longDistanceCount += 1
            default:
                break
            }
        }

        let taxiRatio = totalAmount > 0
            ? Double(truncating: (taxiAmount / totalAmount * 100) as NSDecimalNumber)
            : nil

        return TransportSpendingSummary(
            totalAmount: totalAmount,
            transactionCount: transactions.count,
            taxiAmount: taxiAmount,
            taxiCount: taxiCount,
            publicTransitAmount: publicTransitAmount,
            publicTransitCount: publicTransitCount,
            longDistanceAmount: longDistanceAmount,
            longDistanceCount: longDistanceCount,
            taxiAmountRatio: taxiRatio,
            analysisHint: "交通支出应优先看打车/公共交通/长途的结构与频率，不要只用是否存在单笔大额来判断。"
        )
    }

    private static func buildIncomeCadenceHint(incomes: [Transaction], dayCount: Int) -> String? {
        guard dayCount <= 14 else { return nil }
        let stableIncomeNames: Set<String> = ["工资", "奖金", "兼职", "报销", "房租收入", "公积金"]
        let hasStableIncome = incomes.contains { tx in
            guard let category = tx.category else { return false }
            return stableIncomeNames.contains(category.name)
        }
        if hasStableIncome {
            return "当前是短周期分析；工资/奖金/报销等收入可能低频发生，周收入不能直接代表收支失衡，应结合月度或滚动30天判断。"
        }
        return "当前是短周期分析；若用户是固定工资型收入，本周期收入低不应直接解读为收支失衡。"
    }

    private static func parentCategoryName(for category: Category, topLevelNameMap: [UUID: String]) -> String {
        if category.isTopLevel { return category.name }
        if let parentId = category.parentId, let parentName = topLevelNameMap[parentId] {
            return parentName
        }
        return category.name
    }

    private static func isFixedNecessaryExpense(categoryName: String, parentName: String) -> Bool {
        let fixedNames: Set<String> = ["房租", "房贷", "物业", "保险"]
        return fixedNames.contains(categoryName) || (parentName == "居住" && fixedNames.contains(categoryName))
    }

    private static func isTransportExpense(categoryName: String, parentName: String) -> Bool {
        parentName == "交通" || ["地铁", "打车", "公交", "单车", "加油", "停车", "火车", "机票", "旅行", "过路费"].contains(categoryName)
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
        var performanceSummaries: [HabitPerformanceSummary] = []
        var currentPerformanceByHabitId: [UUID: HabitPerformanceSnapshot] = [:]

        for habit in habits {
            let performance = habitRepo.evaluatePerformance(for: habit, in: range)
            currentPerformanceByHabitId[habit.id] = performance
            completedRecordCount += performance.completedDays
            performanceSummaries.append(Self.makeHabitPerformanceSummary(from: performance))

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
        var previousPerformanceByHabitId: [UUID: HabitPerformanceSnapshot] = [:]
        for habit in habits {
            let previousPerformance = habitRepo.evaluatePerformance(for: habit, in: prevRange)
            previousPerformanceByHabitId[habit.id] = previousPerformance
            previousPeriodCompletedRecordCount += previousPerformance.completedDays
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

        for habit in habits {
            guard let currentPerformance = currentPerformanceByHabitId[habit.id] else { continue }
            let signal = HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: habit.goal?.title,
                profileContext: nil
            )
            guard signal.polarity == .negative else { continue }

            let focus = HabitFocusSummary(
                habitName: habit.name,
                signal: signal,
                current: currentPerformance,
                previous: previousPerformanceByHabitId[habit.id],
                currentStreak: habitRepo.calculateStreakInfo(for: habit).value,
                goalTitle: habit.goal?.title
            )
            guard focus.trend == .worse else { continue }

            let totalDelta = focus.totalValueDelta
            let overLimitDelta = focus.overLimitDaysDelta
            let severity: AnomalySeverity = {
                if let overLimitDelta, overLimitDelta >= 3 { return .critical }
                if let totalDelta, totalDelta >= 10 { return .critical }
                return .warning
            }()

            habitAnomalies.append(AnomalyObservation(
                type: .negativeHabitTrend,
                severity: severity,
                scopeKey: "habit-negative:\(habit.id.uuidString)",
                title: "\(habit.name)控制变弱",
                summary: focus.aiContextLine,
                evidence: [
                    "习惯：\(habit.name)",
                    "趋势：负向习惯发生更多代表变差",
                    "当前：\(focus.aiContextLine)"
                ],
                metricValue: totalDelta ?? Double(overLimitDelta ?? 0),
                baselineValue: previousPerformanceByHabitId[habit.id]?.totalValue,
                ratio: focus.controlRateDelta
            ))
        }

        let context = MemoryInsightHabitContext(
            activeHabitCount: habits.count,
            completedRecordCount: completedRecordCount,
            previousPeriodCompletedRecordCount: previousPeriodCompletedRecordCount,
            streaks: streaks.sorted { $0.streakDays > $1.streakDays },
            averageCompletionRate: overviewStats.averageCompletionRate,
            topPerformingHabits: topPerforming,
            strugglingHabits: struggling,
            habitPerformanceSummaries: performanceSummaries,
            habitCategoryCompletionSummaries: []
        )
        return (context, habitAnomalies)
    }

    // MARK: - Tasks

    private static func makeHabitPerformanceSummary(from snapshot: HabitPerformanceSnapshot) -> HabitPerformanceSummary {
        HabitPerformanceSummary(
            habitName: snapshot.habitName,
            polarity: snapshot.polarity,
            successRule: snapshot.successRule,
            completionRate: snapshot.completionRate,
            totalValue: snapshot.totalValue,
            targetValue: snapshot.targetValue,
            unit: snapshot.unit,
            controlledDays: snapshot.controlledDays,
            overLimitDays: snapshot.overLimitDays,
            completedDays: snapshot.completedDays,
            totalDays: snapshot.totalDays
        )
    }

    private func buildTaskContext(start: Date, end: Date) -> (context: MemoryInsightTaskContext, anomalies: [AnomalyObservation]) {
        let context = dataContext
        let endExclusive = end.addingDays(1)

        var completedCount = 0
        var importantCompletedTasks: [String] = []

        do {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(
                format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                endExclusive as CVarArg
            )
            let completedTasks = try context.fetch(request)
            completedCount = completedTasks.count

            importantCompletedTasks = completedTasks
                .filter { $0.priority >= 2 }
                .map { $0.title }
                .prefix(5)
                .map { String($0) }
        } catch {
            Self.logger.error("构建任务上下文失败：\(error.localizedDescription)")
        }

        let stats = todoRepo.getCompletionStats(from: start, to: endExclusive)
        let trend = todoRepo.getCompletionTrend(from: start, to: endExclusive)

        let totalActive = stats.activeBacklogCount

        // 任务堆积检测
        var taskAnomalies: [AnomalyObservation] = []
        if totalActive >= 10 && stats.carriedOverBacklogCount >= 3 {
            let severity: AnomalySeverity = stats.carriedOverBacklogCount > 5 ? .critical : .warning
            taskAnomalies.append(AnomalyObservation(
                type: .taskOverload,
                severity: severity,
                scopeKey: "task:overdue",
                title: "任务堆积",
                summary: "\(totalActive) 个未完成任务中 \(stats.carriedOverBacklogCount) 个是历史积压",
                evidence: ["未完成任务：\(totalActive)", "历史积压：\(stats.carriedOverBacklogCount)"],
                metricValue: Double(stats.carriedOverBacklogCount),
                baselineValue: nil,
                ratio: nil
            ))
        }

        let taskContext = MemoryInsightTaskContext(
            completedCount: completedCount,
            overdueCount: stats.overdueInPeriod,
            importantCompletedTasks: importantCompletedTasks,
            totalCount: stats.dueInPeriod,
            completionRate: stats.completionRate,
            highPriorityCompletionRate: stats.highPriorityCompletionRate,
            dailyCompletionTrend: trend,
            dueInPeriod: stats.dueInPeriod,
            createdInPeriod: stats.createdInPeriod,
            completedInPeriod: stats.completedInPeriod,
            newOverdueInPeriod: stats.overdueInPeriod,
            carriedOverBacklogCount: stats.carriedOverBacklogCount,
            activeBacklogCount: stats.activeBacklogCount,
            periodCompletionScopeNote: "完成率只看本周期到期任务；历史积压仅作为 backlog 背景，不应写成“本周任务全部没完成”。"
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

    // MARK: - Life Trajectory: Daily Snapshots

    private func buildDailySnapshots(start: Date, end: Date) async -> [DailyLifeSnapshot] {
        let calendar = Calendar.current
        let dateFormatter = Self.makeDateFormatter()
        let currencyFormatter = Self.makeCurrencyFormatter()

        // 批量获取数据
        let endExclusive = end.addingDays(1)
        let dailyExpenses = await Self.fetchDailyExpenseMap(
            financeRepo: financeRepo,
            start: start,
            end: endExclusive
        )
        let dailyTaskMap = fetchDailyTaskMap(
            todoRepo: todoRepo,
            start: start,
            end: end
        )
        let overdueTasks = todoRepo.getOverdueTasks()
        let habitRates = Self.fetchDailyHabitRates(
            habitRepo: habitRepo,
            start: start,
            end: end
        )
        let thoughtCounts = thoughtRepo.getThoughtCountByDay(
            from: start,
            to: endExclusive
        )

        // 按天聚合逾期
        var overdueByDay: [String: Int] = [:]
        let overdueDateFormatter = DateFormatter()
        overdueDateFormatter.locale = Locale(identifier: "zh_CN")
        overdueDateFormatter.dateFormat = "yyyy-MM-dd"
        for task in overdueTasks {
            guard let dueDate = task.dueDate else { continue }
            let key = overdueDateFormatter.string(from: dueDate)
            overdueByDay[key, default: 0] += 1
        }

        // 计算全期日均消费，用于异常判定
        let totalExpense = dailyExpenses.values.reduce(Decimal(0), +)
        let totalDays = max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 1)
        let avgDailyExpense = totalExpense / Decimal(totalDays)

        var snapshots: [DailyLifeSnapshot] = []
        var current = start
        while current <= end {
            let key = dateFormatter.string(from: current)
            let dayExpense = dailyExpenses[key] ?? Decimal(0)
            let taskInfo = dailyTaskMap[key] ?? (created: 0, completed: 0)
            let dayOverdue = overdueByDay[key] ?? 0
            let habitRate = habitRates[key]
            let thoughtCount = thoughtCounts[key] ?? 0

            let signals = Self.detectDailySignals(
                dayExpense: dayExpense,
                avgDailyExpense: avgDailyExpense,
                overdueCount: dayOverdue,
                habitRate: habitRate
            )

            snapshots.append(DailyLifeSnapshot(
                date: key,
                expenseTotalText: currencyFormatter.string(from: dayExpense as NSDecimalNumber) ?? "¥0.00",
                taskCreatedCount: taskInfo.created,
                taskCompletedCount: taskInfo.completed,
                overdueCount: dayOverdue,
                habitCompletionRate: habitRate,
                thoughtCount: thoughtCount,
                topSignals: signals
            ))

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return snapshots
    }

    // MARK: - Life Trajectory: Life Events

    private func buildLifeEvents(start: Date, end: Date) async -> [LifeEvent] {
        let dateFormatter = Self.makeDateFormatter()
        let currencyFormatter = Self.makeCurrencyFormatter()
        let endExclusive = end.addingDays(1)

        var events: [LifeEvent] = []

        // 财务事件
        await Self.collectFinanceEvents(
            financeRepo: financeRepo,
            start: start,
            end: endExclusive,
            dateFormatter: dateFormatter,
            currencyFormatter: currencyFormatter,
            into: &events
        )

        // 任务事件
        collectTaskEvents(
            todoRepo: todoRepo,
            start: start,
            end: end,
            dateFormatter: dateFormatter,
            into: &events
        )

        // 习惯事件
        Self.collectHabitEvents(
            habitRepo: habitRepo,
            start: start,
            end: end,
            dateFormatter: dateFormatter,
            into: &events
        )

        // 观点事件
        Self.collectThoughtEvents(
            thoughtRepo: thoughtRepo,
            start: start,
            end: endExclusive,
            dateFormatter: dateFormatter,
            into: &events
        )

        return Self.prioritizeEvents(events)
    }

    // MARK: - Life Trajectory: Personal Baseline

    private func buildPersonalBaseline(observationStart: Date) async -> PersonalBaseline? {
        let baselineEnd = observationStart.addingDays(-1)
        let baselineStart = baselineEnd.addingDays(-27) // 4 周
        let endExclusive = baselineEnd.addingDays(1)

        // 获取基线期交易
        let transactions: [Transaction]
        do {
            transactions = try await financeRepo.getTransactions(from: baselineStart, to: endExclusive)
        } catch {
            Self.logger.error("构建个人基线获取交易失败：\(error.localizedDescription)")
            return nil
        }

        let expenses = transactions.filter { $0.type == "expense" }
        let calendar = Calendar.current
        let weekCount = 4

        // 按周聚合支出（跳过空周）
        let weeklyExpenses = Self.aggregateWeeklyExpenses(
            expenses: expenses,
            start: baselineStart,
            weekCount: weekCount,
            calendar: calendar
        )

        let validWeeks = weeklyExpenses.filter { $0 > 0 }
        guard validWeeks.count >= 2 else { return nil }

        let weeklyAvg = validWeeks.reduce(Decimal(0), +) / Decimal(validWeeks.count)
        let currencyFormatter = Self.makeCurrencyFormatter()

        // 分类周均
        let categoryAverages = Self.aggregateCategoryBaselines(
            expenses: expenses,
            validWeekCount: validWeeks.count,
            currencyFormatter: currencyFormatter
        )

        // 任务完成率周均
        let taskRate = Self.aggregateTaskCompletionRate(
            todoRepo: todoRepo,
            start: baselineStart,
            end: baselineEnd,
            weekCount: weekCount,
            calendar: calendar
        )

        // 习惯完成率周均
        let habitRate = Self.aggregateHabitCompletionRate(
            habitRepo: habitRepo,
            start: baselineStart,
            end: baselineEnd,
            weekCount: weekCount,
            calendar: calendar
        )

        // 高消费工作日
        let highExpenseWeekdays = Self.detectHighExpenseWeekdays(
            expenses: expenses,
            weeklyAvg: weeklyAvg,
            calendar: calendar
        )

        return PersonalBaseline(
            baselineStart: baselineStart,
            baselineEnd: baselineEnd,
            effectiveWeekCount: validWeeks.count,
            expenseWeeklyAverageText: currencyFormatter.string(from: weeklyAvg as NSDecimalNumber),
            categoryAverages: categoryAverages,
            taskCompletionRateAverage: taskRate,
            habitCompletionRateAverage: habitRate,
            usualHighExpenseWeekdays: highExpenseWeekdays
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
                moduleSnapshots: payload.cards.compactMap { card in
                    guard let module = mapCardTypeToModule(card.type) else { return nil }
                    return ModuleSnapshot(
                        module: module,
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
        let milestones = buildMilestoneContext(start: yearStart, end: yearEnd)
        let personalProfileContext = await buildPersonalProfileContext()

        let correlations = CrossModuleCorrelator.detect(
            finance: finance,
            habits: habits,
            tasks: tasks,
            thoughts: thoughts
        )

        let rawContext = MemoryInsightContext(
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
            previousPeriodReview: nil,
            personalProfileContext: personalProfileContext
        )

        return Self.enforceAnnualTokenBudget(rawContext)
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
                weekdayWeekendSpending: nil, semanticSummary: nil
            ),
            habits: MemoryInsightHabitContext(
                activeHabitCount: 0, completedRecordCount: 0,
                previousPeriodCompletedRecordCount: 0, streaks: [],
                averageCompletionRate: nil, topPerformingHabits: [], strugglingHabits: [],
                habitPerformanceSummaries: [],
                habitCategoryCompletionSummaries: []
            ),
            tasks: MemoryInsightTaskContext(
                completedCount: 0, overdueCount: 0, importantCompletedTasks: [],
                totalCount: 0, completionRate: 0,
                highPriorityCompletionRate: nil, dailyCompletionTrend: [],
                dueInPeriod: 0, createdInPeriod: 0, completedInPeriod: 0,
                newOverdueInPeriod: 0, carriedOverBacklogCount: 0,
                activeBacklogCount: 0,
                periodCompletionScopeNote: "完成率只看本周期到期任务；历史积压单独统计。"
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
            previousPeriodReview: nil,
            personalProfileContext: nil
        )
    }

    private func mapCardTypeToModule(_ cardType: MemoryInsightCardType) -> InsightModule? {
        switch cardType {
        case .finance: return .finance
        case .habit: return .habit
        case .task: return .task
        case .thought: return .thought
        case .overview, .crossDomain, .milestone, .anomaly: return nil
        }
    }

    // MARK: - Milestones

    private func buildMilestoneContext(start: Date, end: Date) -> [MemoryInsightMilestoneContext] {
        let allMilestones = MilestoneDetector.detect(context: dataContext)

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

    /// CJK 友好的 token 估算
    private static func estimateTokenCount(_ string: String) -> Int {
        Int(Double(string.count) * 1.5)
    }

    private static func enforceTokenBudget(
        _ context: MemoryInsightContext,
        periodType: MemoryInsightPeriodType
    ) -> MemoryInsightContext {
        let budget: Int
        switch periodType {
        case .daily: budget = dailyTokenBudget
        case .weekly: budget = weeklyTokenBudget
        case .monthly: budget = monthlyTokenBudget
        case .quarterly, .custom: budget = annualTokenBudget
        }

        var current = context

        // 渐进式裁剪：逐步削减直到低于预算
        // 步骤 1：裁剪 thoughts.textContents 到 5 条
        if estimateContextTokens(current) > budget {
            if current.thoughts.textContents.count > 5 {
                let truncated = MemoryInsightThoughtContext(
                    totalCount: current.thoughts.totalCount,
                    recentSnippets: current.thoughts.recentSnippets,
                    textContents: Array(current.thoughts.textContents.prefix(5)),
                    moodDistribution: current.thoughts.moodDistribution,
                    topTags: current.thoughts.topTags,
                    thoughtSentimentSummary: current.thoughts.thoughtSentimentSummary
                )
                current = rebuildContext(from: current, thoughts: truncated)
            }
        }

        // 步骤 2：裁剪 lifeEvents 到 15 条
        if estimateContextTokens(current) > budget {
            if let events = current.lifeEvents, events.count > 15 {
                current = rebuildContext(from: current, lifeEvents: Array(events.prefix(15)))
            }
        }

        // 步骤 3：裁剪 dailyExpenses 和 dailyCompletionTrend 到最近 14 天
        if estimateContextTokens(current) > budget {
            if current.finance.dailyExpenses.count > 14 {
                let truncated = MemoryInsightFinanceContext(
                    totalExpense: current.finance.totalExpense,
                    totalIncome: current.finance.totalIncome,
                    topCategories: current.finance.topCategories,
                    dailyExpenses: Array(current.finance.dailyExpenses.suffix(14)),
                    previousPeriodExpense: current.finance.previousPeriodExpense,
                    budgetPerformance: current.finance.budgetPerformance,
                    anomalyDescriptions: current.finance.anomalyDescriptions,
                    weekdayWeekendSpending: current.finance.weekdayWeekendSpending,
                    semanticSummary: current.finance.semanticSummary
                )
                current = rebuildContext(from: current, finance: truncated)
            }
            if current.tasks.dailyCompletionTrend.count > 14 {
                let truncated = MemoryInsightTaskContext(
                    completedCount: current.tasks.completedCount,
                    overdueCount: current.tasks.overdueCount,
                    importantCompletedTasks: current.tasks.importantCompletedTasks,
                    totalCount: current.tasks.totalCount,
                    completionRate: current.tasks.completionRate,
                    highPriorityCompletionRate: current.tasks.highPriorityCompletionRate,
                    dailyCompletionTrend: Array(current.tasks.dailyCompletionTrend.suffix(14)),
                    dueInPeriod: current.tasks.dueInPeriod,
                    createdInPeriod: current.tasks.createdInPeriod,
                    completedInPeriod: current.tasks.completedInPeriod,
                    newOverdueInPeriod: current.tasks.newOverdueInPeriod,
                    carriedOverBacklogCount: current.tasks.carriedOverBacklogCount,
                    activeBacklogCount: current.tasks.activeBacklogCount,
                    periodCompletionScopeNote: current.tasks.periodCompletionScopeNote
                )
                current = rebuildContext(from: current, tasks: truncated)
            }
        }

        return current
    }

    /// 估算上下文 token 数量
    private static func estimateContextTokens(_ context: MemoryInsightContext) -> Int {
        guard let encoded = try? JSONEncoder().encode(context),
              let string = String(data: encoded, encoding: .utf8) else {
            return 0
        }
        return estimateTokenCount(string)
    }

    /// 重建上下文（只替换指定字段）
    private static func rebuildContext(
        from context: MemoryInsightContext,
        finance: MemoryInsightFinanceContext? = nil,
        tasks: MemoryInsightTaskContext? = nil,
        thoughts: MemoryInsightThoughtContext? = nil,
        lifeEvents: [LifeEvent]? = nil
    ) -> MemoryInsightContext {
        MemoryInsightContext(
            periodType: context.periodType,
            periodStart: context.periodStart,
            periodEnd: context.periodEnd,
            generatedAt: context.generatedAt,
            localeIdentifier: context.localeIdentifier,
            finance: finance ?? context.finance,
            habits: context.habits,
            tasks: tasks ?? context.tasks,
            thoughts: thoughts ?? context.thoughts,
            milestones: context.milestones,
            crossModuleCorrelations: context.crossModuleCorrelations,
            monthlyInsightDigests: context.monthlyInsightDigests,
            anomalies: context.anomalies,
            previousPeriodReview: context.previousPeriodReview,
            dailySnapshots: context.dailySnapshots,
            lifeEvents: lifeEvents ?? context.lifeEvents,
            personalBaseline: context.personalBaseline,
            personalProfileContext: context.personalProfileContext
        )
    }

    /// 年度上下文专用预算裁剪
    private static func enforceAnnualTokenBudget(_ context: MemoryInsightContext) -> MemoryInsightContext {
        var current = context

        // 年度上下文优先裁剪月度摘要（最多保留 6 条）
        if estimateContextTokens(current) > annualTokenBudget {
            if current.monthlyInsightDigests.count > 6 {
                current = MemoryInsightContext(
                    periodType: current.periodType,
                    periodStart: current.periodStart,
                    periodEnd: current.periodEnd,
                    generatedAt: current.generatedAt,
                    localeIdentifier: current.localeIdentifier,
                    finance: current.finance,
                    habits: current.habits,
                    tasks: current.tasks,
                    thoughts: current.thoughts,
                    milestones: current.milestones,
                    crossModuleCorrelations: current.crossModuleCorrelations,
                    monthlyInsightDigests: Array(current.monthlyInsightDigests.prefix(6)),
                    anomalies: current.anomalies,
                    previousPeriodReview: current.previousPeriodReview,
                    dailySnapshots: nil,
                    lifeEvents: nil,
                    personalBaseline: nil,
                    personalProfileContext: current.personalProfileContext
                )
            }
        }

        // 再裁剪想法文本
        if estimateContextTokens(current) > annualTokenBudget {
            if current.thoughts.textContents.count > 3 {
                let truncated = MemoryInsightThoughtContext(
                    totalCount: current.thoughts.totalCount,
                    recentSnippets: current.thoughts.recentSnippets,
                    textContents: Array(current.thoughts.textContents.prefix(3)),
                    moodDistribution: current.thoughts.moodDistribution,
                    topTags: current.thoughts.topTags,
                    thoughtSentimentSummary: current.thoughts.thoughtSentimentSummary
                )
                current = rebuildContext(from: current, thoughts: truncated)
            }
        }

        return current
    }

    // MARK: - Snapshot Hash

    static func computeHash(_ context: MemoryInsightContext) -> String {
        // 排除 generatedAt 运行时字段，保证相同业务数据生成稳定 hash
        let stableContext = MemoryInsightContext(
            periodType: context.periodType,
            periodStart: context.periodStart,
            periodEnd: context.periodEnd,
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: context.localeIdentifier,
            finance: context.finance,
            habits: context.habits,
            tasks: context.tasks,
            thoughts: context.thoughts,
            milestones: context.milestones,
            crossModuleCorrelations: context.crossModuleCorrelations,
            monthlyInsightDigests: context.monthlyInsightDigests,
            anomalies: context.anomalies,
            previousPeriodReview: context.previousPeriodReview,
            dailySnapshots: context.dailySnapshots,
            lifeEvents: context.lifeEvents,
            personalBaseline: context.personalBaseline,
            personalProfileContext: context.personalProfileContext
        )
        guard let encoded = try? JSONEncoder().encode(stableContext) else { return "" }
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

    // MARK: - Life Trajectory Helpers

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func makeCurrencyFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        return formatter
    }

    private static func fetchDailyExpenseMap(
        financeRepo: FinanceRepository,
        start: Date,
        end: Date
    ) async -> [String: Decimal] {
        do {
            let transactions = try await financeRepo.getTransactions(from: start, to: end)
            let dateFormatter = makeDateFormatter()
            var map: [String: Decimal] = [:]
            for t in transactions where t.type == "expense" {
                let key = dateFormatter.string(from: t.date)
                map[key, default: 0] += t.amount.decimalValue
            }
            return map
        } catch {
            logger.error("获取每日支出失败：\(error.localizedDescription)")
            return [:]
        }
    }

    private func fetchDailyTaskMap(
        todoRepo: TodoRepository,
        start: Date,
        end: Date
    ) -> [String: (created: Int, completed: Int)] {
        let context = dataContext
        let dateFormatter = Self.makeDateFormatter()
        var map: [String: (created: Int, completed: Int)] = [:]

        do {
            // 已完成任务
            let completedRequest = TodoTask.fetchRequest()
            completedRequest.predicate = NSPredicate(
                format: "completedAt >= %@ AND completedAt < %@ AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                end.addingDays(1) as CVarArg
            )
            let completedTasks = try context.fetch(completedRequest)
            for task in completedTasks {
                guard let date = task.completedAt else { continue }
                let key = dateFormatter.string(from: date)
                map[key, default: (0, 0)].completed += 1
            }

            // 创建的任务
            let createdRequest = TodoTask.fetchRequest()
            createdRequest.predicate = NSPredicate(
                format: "createdAt >= %@ AND createdAt < %@ AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                end.addingDays(1) as CVarArg
            )
            let createdTasks = try context.fetch(createdRequest)
            for task in createdTasks {
                let key = dateFormatter.string(from: task.createdAt)
                map[key, default: (0, 0)].created += 1
            }
        } catch {
            Self.logger.error("获取每日任务数据失败：\(error.localizedDescription)")
        }
        return map
    }

    private static func fetchDailyHabitRates(
        habitRepo: HabitRepository,
        start: Date,
        end: Date
    ) -> [String: Double] {
        let habits = habitRepo.activeHabits
            .filter { $0.isCheckInType && !$0.isBadHabit }
        guard !habits.isEmpty else { return [:] }

        let dateFormatter = makeDateFormatter()
        let calendar = Calendar.current
        var completionByDate: [String: (completed: Int, total: Int)] = [:]

        var current = start
        while current <= end {
            let key = dateFormatter.string(from: current)
            completionByDate[key] = (0, habits.count)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: start...end.addingDays(1))
            for record in records where record.isCompleted {
                let key = dateFormatter.string(from: record.date)
                if completionByDate[key] != nil {
                    completionByDate[key]!.completed += 1
                }
            }
        }

        var rates: [String: Double] = [:]
        for (key, counts) in completionByDate {
            guard counts.total > 0 else { continue }
            rates[key] = Double(counts.completed) / Double(counts.total)
        }
        return rates
    }

    private static func detectDailySignals(
        dayExpense: Decimal,
        avgDailyExpense: Decimal,
        overdueCount: Int,
        habitRate: Double?
    ) -> [String] {
        var signals: [String] = []

        // 高消费日：超过日均 2 倍
        if avgDailyExpense > 0, dayExpense > avgDailyExpense * 2 {
            signals.append("高消费日")
        }

        // 逾期堆积
        if overdueCount >= 3 {
            signals.append("逾期任务堆积")
        }

        // 习惯完成率低
        if let rate = habitRate, rate < 0.3 {
            signals.append("习惯完成率低")
        }

        return signals
    }

    private static func collectFinanceEvents(
        financeRepo: FinanceRepository,
        start: Date,
        end: Date,
        dateFormatter: DateFormatter,
        currencyFormatter: NumberFormatter,
        into events: inout [LifeEvent]
    ) async {
        do {
            let transactions = try await financeRepo.getTransactions(from: start, to: end)

            // 高额消费事件（> 200）
            for t in transactions where t.type == "expense" {
                let amount = t.amount.decimalValue
                guard amount >= 200 else { continue }
                events.append(LifeEvent(
                    id: UUID().uuidString,
                    date: dateFormatter.string(from: t.date),
                    module: "finance",
                    type: "expense",
                    title: String(t.note?.prefix(30) ?? (t.category?.name ?? "未分类").prefix(20)),
                    valueText: currencyFormatter.string(from: t.amount),
                    tags: t.tags ?? [],
                    sourceId: t.id.uuidString
                ))
            }

            // 收入事件
            for t in transactions where t.type == "income" {
                let amount = t.amount.decimalValue
                guard amount >= 500 else { continue }
                events.append(LifeEvent(
                    id: UUID().uuidString,
                    date: dateFormatter.string(from: t.date),
                    module: "finance",
                    type: "income",
                    title: String(t.note?.prefix(30) ?? (t.category?.name ?? "未分类").prefix(20)),
                    valueText: currencyFormatter.string(from: t.amount),
                    tags: t.tags ?? [],
                    sourceId: t.id.uuidString
                ))
            }
        } catch {
            logger.error("收集财务事件失败：\(error.localizedDescription)")
        }
    }

    private func collectTaskEvents(
        todoRepo: TodoRepository,
        start: Date,
        end: Date,
        dateFormatter: DateFormatter,
        into events: inout [LifeEvent]
    ) {
        let context = dataContext
        let endExclusive = end.addingDays(1)

        do {
            // 高优先级已完成任务
            let completedRequest = TodoTask.fetchRequest()
            completedRequest.predicate = NSPredicate(
                format: "completed == YES AND completedAt >= %@ AND completedAt < %@ AND priority >= %d AND deletedFlag == NO AND archived == NO",
                start as CVarArg,
                endExclusive as CVarArg,
                2
            )
            let completedTasks = try context.fetch(completedRequest)
            for task in completedTasks {
                guard let completedAt = task.completedAt else { continue }
                events.append(LifeEvent(
                    id: UUID().uuidString,
                    date: dateFormatter.string(from: completedAt),
                    module: "task",
                    type: "taskCompleted",
                    title: String(task.title.prefix(30)),
                    valueText: nil,
                    tags: [],
                    sourceId: task.id.uuidString
                ))
            }

            // 逾期任务
            let overdueTasks = todoRepo.getOverdueTasks()
            for task in overdueTasks.prefix(10) {
                guard let dueDate = task.dueDate else { continue }
                events.append(LifeEvent(
                    id: UUID().uuidString,
                    date: dateFormatter.string(from: dueDate),
                    module: "task",
                    type: "taskOverdue",
                    title: String(task.title.prefix(30)),
                    valueText: nil,
                    tags: [],
                    sourceId: task.id.uuidString
                ))
            }
        } catch {
            Self.logger.error("收集任务事件失败：\(error.localizedDescription)")
        }
    }

    private static func collectHabitEvents(
        habitRepo: HabitRepository,
        start: Date,
        end: Date,
        dateFormatter: DateFormatter,
        into events: inout [LifeEvent]
    ) {
        let habits = habitRepo.activeHabits.filter { $0.isCheckInType && !$0.isBadHabit }
        let range = start...end.addingDays(1)

        for habit in habits {
            let records = habitRepo.getRecords(for: habit, in: range)
            let streakInfo = habitRepo.calculateStreakInfo(for: habit)

            // 习惯断连（>= 3 天）
            if streakInfo.value == 0 {
                let missedDays = consecutiveMissedDays(
                    for: habit,
                    upTo: end,
                    habitRepo: habitRepo,
                    calendar: Calendar.current,
                    dateFormatter: dateFormatter
                )
                if missedDays >= 3 {
                    events.append(LifeEvent(
                        id: UUID().uuidString,
                        date: dateFormatter.string(from: end),
                        module: "habit",
                        type: "habitMissed",
                        title: "\(habit.name)已断连\(missedDays)天",
                        valueText: nil,
                        tags: [],
                        sourceId: habit.id.uuidString
                    ))
                }
            }

            // 连续打卡 >= 7 天
            if streakInfo.value >= 7 {
                let completedRecords = records.filter { $0.isCompleted }
                if let latestRecord = completedRecords.last {
                    events.append(LifeEvent(
                        id: UUID().uuidString,
                        date: dateFormatter.string(from: latestRecord.date),
                        module: "habit",
                        type: "habitCompleted",
                        title: "\(habit.name)连续打卡\(streakInfo.value)天",
                        valueText: nil,
                        tags: [],
                        sourceId: habit.id.uuidString
                    ))
                }
            }
        }
    }

    private static func collectThoughtEvents(
        thoughtRepo: ThoughtRepository,
        start: Date,
        end: Date,
        dateFormatter: DateFormatter,
        into events: inout [LifeEvent]
    ) {
        do {
            let filters = ThoughtFilters(startDate: start, endDate: end)
            let thoughts = try thoughtRepo.search(query: "", filters: filters)
            for thought in thoughts.prefix(10) {
                guard !thought.content.isEmpty else { continue }
                let tagNames = (thought.tags as? Set<ThoughtTag>)?.map(\.name) ?? []
                events.append(LifeEvent(
                    id: UUID().uuidString,
                    date: dateFormatter.string(from: thought.createdAt),
                    module: "thought",
                    type: "thoughtCreated",
                    title: String(thought.content.prefix(30)),
                    valueText: nil,
                    tags: tagNames,
                    sourceId: thought.id.uuidString
                ))
            }
        } catch {
            logger.error("收集观点事件失败：\(error.localizedDescription)")
        }
    }

    /// 按优先级排序并截取前 30 条事件
    private static func prioritizeEvents(_ events: [LifeEvent]) -> [LifeEvent] {
        let typePriority: [String: Int] = [
            "expense": 5,     // 高额消费（已通过金额阈值筛选）
            "income": 4,
            "taskCompleted": 3,
            "taskOverdue": 6,  // 逾期最高优先
            "habitMissed": 5,
            "habitCompleted": 2,
            "thoughtCreated": 1
        ]

        return events
            .sorted { (typePriority[$0.type] ?? 0) > (typePriority[$1.type] ?? 0) }
            .prefix(30)
            .map { $0 }
    }

    // MARK: - Personal Baseline Helpers

    /// 按周聚合支出
    private static func aggregateWeeklyExpenses(
        expenses: [Transaction],
        start: Date,
        weekCount: Int,
        calendar: Calendar
    ) -> [Decimal] {
        var weeklyTotals = Array(repeating: Decimal(0), count: weekCount)

        for transaction in expenses {
            let daysSinceStart = calendar.dateComponents([.day], from: start, to: transaction.date).day ?? 0
            let weekIndex = min(daysSinceStart / 7, weekCount - 1)
            guard weekIndex >= 0 else { continue }
            weeklyTotals[weekIndex] += transaction.amount.decimalValue
        }

        return weeklyTotals
    }

    /// 分类周均支出
    private static func aggregateCategoryBaselines(
        expenses: [Transaction],
        validWeekCount: Int,
        currencyFormatter: NumberFormatter
    ) -> [CategoryBaseline] {
        var categoryMap: [String: Decimal] = [:]
        for t in expenses {
            guard let category = t.category else { continue }
            categoryMap[category.name, default: 0] += t.amount.decimalValue
        }

        let weeklyDivisor = Decimal(validWeekCount)
        return categoryMap
            .map { name, total -> CategoryBaseline in
                let weeklyAvg = total / weeklyDivisor
                return CategoryBaseline(
                    categoryName: name,
                    weeklyAverageText: currencyFormatter.string(from: weeklyAvg as NSDecimalNumber) ?? "¥0.00"
                )
            }
            .sorted { $0.weeklyAverageText > $1.weeklyAverageText }
            .prefix(10)
            .map { $0 }
    }

    /// 基线期任务完成率周均
    private static func aggregateTaskCompletionRate(
        todoRepo: TodoRepository,
        start: Date,
        end: Date,
        weekCount: Int,
        calendar: Calendar
    ) -> Double? {
        var weeklyRates: [Double] = []
        for week in 0..<weekCount {
            guard let weekStart = calendar.date(byAdding: .day, value: week * 7, to: start),
                  let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { continue }
            let effectiveWeekEnd = min(weekEnd, end)
            let stats = todoRepo.getCompletionStats(from: weekStart, to: effectiveWeekEnd)
            if stats.dueInPeriod > 0 {
                weeklyRates.append(stats.completionRate)
            }
        }
        guard weeklyRates.count >= 2 else { return nil }
        return weeklyRates.reduce(0, +) / Double(weeklyRates.count)
    }

    /// 基线期习惯完成率周均
    private static func aggregateHabitCompletionRate(
        habitRepo: HabitRepository,
        start: Date,
        end: Date,
        weekCount: Int,
        calendar: Calendar
    ) -> Double? {
        let habits = habitRepo.activeHabits.filter { $0.isCheckInType && !$0.isBadHabit }
        guard !habits.isEmpty else { return nil }

        var weeklyRates: [Double] = []
        for week in 0..<weekCount {
            guard let weekStart = calendar.date(byAdding: .day, value: week * 7, to: start),
                  let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { continue }
            let effectiveWeekEnd = min(weekEnd, end)

            var totalScheduled = 0
            var totalCompleted = 0
            for habit in habits {
                let habitRecords = habitRepo.getRecords(for: habit, in: weekStart...effectiveWeekEnd.addingDays(1))
                totalScheduled += 7
                totalCompleted += habitRecords.filter { $0.isCompleted }.count
            }

            if totalScheduled > 0 {
                weeklyRates.append(Double(totalCompleted) / Double(totalScheduled))
            }
        }
        guard weeklyRates.count >= 2 else { return nil }
        return weeklyRates.reduce(0, +) / Double(weeklyRates.count)
    }

    /// 检测高消费工作日
    private static func detectHighExpenseWeekdays(
        expenses: [Transaction],
        weeklyAvg: Decimal,
        calendar: Calendar
    ) -> [String] {
        let dailyAvg = weeklyAvg / 7
        guard dailyAvg > 0 else { return [] }

        // 按星期聚合
        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        var weekdayTotals = Array(repeating: Decimal(0), count: 7)
        var weekdayCounts = Array(repeating: 0, count: 7)

        for t in expenses {
            let weekday = calendar.component(.weekday, from: t.date)
            // weekday: 1=Sunday ... 7=Saturday
            let index = weekday - 1
            guard index >= 0 && index < 7 else { continue }
            weekdayTotals[index] += t.amount.decimalValue
            weekdayCounts[index] += 1
        }

        var highWeekdays: [String] = []
        for i in 0..<7 {
            guard weekdayCounts[i] > 0 else { continue }
            let avgForWeekday = weekdayTotals[i] / Decimal(weekdayCounts[i])
            // 工作日平均日消费 >= 1.5 倍日均
            if avgForWeekday >= dailyAvg * Decimal(1.5) {
                highWeekdays.append(weekdayNames[i])
            }
        }

        return highWeekdays
    }
}
