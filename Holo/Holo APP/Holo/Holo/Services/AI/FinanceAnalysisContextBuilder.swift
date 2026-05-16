//
//  FinanceAnalysisContextBuilder.swift
//  Holo
//
//  财务分析上下文构建器
//  调用 FinanceRepository+Aggregation 获取交易和分类聚合数据
//

import Foundation
import os.log

struct FinanceAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "FinanceAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> FinanceAnalysisContext? {
        let repo = FinanceRepository.shared
        let calendar = Calendar.current
        let startInclusive = calendar.startOfDay(for: request.start)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            logger.error("无法计算结束日期")
            return nil
        }

        do {
            let transactions = try await repo.getTransactions(from: startInclusive, to: endExclusive)

            let expenses = transactions.filter { $0.transactionType == .expense }
            let incomes = transactions.filter { $0.transactionType == .income }

            let totalExpense = expenses.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            let totalIncome = incomes.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

            guard totalExpense != 0 || totalIncome != 0 || !transactions.isEmpty else {
                return nil
            }

            let dayCount = max(calendar.dateComponents([.day], from: startInclusive, to: endExclusive).day ?? 1, 1)
            let averageDailyExpense = totalExpense / Decimal(dayCount)

            // Top 5 支出分类
            let categoryAggregations = try await repo.getTopLevelCategoryAggregations(
                from: startInclusive,
                to: endExclusive,
                type: .expense
            )
            let topLevelCategories = try await repo.getTopLevelCategories(by: .expense)
            let topLevelNameMap = Dictionary(
                uniqueKeysWithValues: topLevelCategories.map { ($0.id, $0.name) }
            )
            let topCategories = categoryAggregations.prefix(5).map { agg in
                FinanceCategoryItem(
                    categoryName: agg.category.name,
                    amount: agg.amount,
                    percentage: agg.percentage
                )
            }

            // 子分类明细（Top 3 一级分类的子分类拆解）
            let subCategoryDetails = buildSubCategoryDetails(
                expenses: expenses,
                topCategoryAggregations: categoryAggregations
            )

            // 月度分解（最多 12 个月）
            let monthlyBreakdown = buildMonthlyBreakdown(
                transactions: transactions,
                start: startInclusive,
                end: endExclusive
            )

            // 上周期对比 + 分类趋势
            var previousPeriodExpense: Decimal?
            var categoryTrends: [CategoryTrendItem]?
            if let compStart = request.comparisonStart,
               let compEnd = request.comparisonEnd {
                let compStartDay = calendar.startOfDay(for: compStart)
                let compEndExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: compEnd))
                if let compEndExcl = compEndExclusive {
                    let compTransactions = try await repo.getTransactions(from: compStartDay, to: compEndExcl)
                    let compExpenses = compTransactions.filter { $0.transactionType == .expense }
                    previousPeriodExpense = compExpenses.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

                    categoryTrends = buildCategoryTrends(
                        currentCategoryAggregations: categoryAggregations,
                        comparisonExpenses: compExpenses,
                        topLevelCategories: topLevelCategories
                    )
                }
            }

            // 异常检测（日支出超过均值的 2 倍）
            let anomalyDescriptions = detectAnomalies(
                expenses: expenses,
                averageDaily: averageDailyExpense,
                calendar: calendar
            )

            // 预算表现（仅在区间匹配当前周/月时）
            let budgetPerformance = buildBudgetPerformance(
                start: startInclusive,
                endExclusive: endExclusive,
                totalExpense: totalExpense
            )

            // 消费模式
            let spendingPatterns = buildSpendingPatterns(
                expenses: expenses,
                start: startInclusive,
                end: endExclusive,
                calendar: calendar
            )

            let semanticSummary = buildSemanticSummary(
                expenses: expenses,
                incomes: incomes,
                topLevelNameMap: topLevelNameMap,
                dayCount: dayCount
            )

            return FinanceAnalysisContext(
                totalExpense: totalExpense,
                totalIncome: totalIncome,
                transactionCount: transactions.count,
                averageDailyExpense: averageDailyExpense,
                topExpenseCategories: topCategories,
                monthlyBreakdown: monthlyBreakdown,
                previousPeriodExpense: previousPeriodExpense,
                anomalyDescriptions: anomalyDescriptions,
                budgetPerformance: budgetPerformance,
                subCategoryDetails: subCategoryDetails.isEmpty ? nil : subCategoryDetails,
                categoryTrends: categoryTrends,
                spendingPatterns: spendingPatterns,
                semanticSummary: semanticSummary
            )

        } catch {
            logger.error("构建财务分析上下文失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Semantic Summary

    private func buildSemanticSummary(
        expenses: [Transaction],
        incomes: [Transaction],
        topLevelNameMap: [UUID: String],
        dayCount: Int
    ) -> FinanceSemanticSummary {
        var fixedMap: [String: Decimal] = [:]
        var fixedTotal: Decimal = 0
        var transportTransactions: [Transaction] = []

        for tx in expenses {
            let parentName = parentCategoryName(for: tx.category, topLevelNameMap: topLevelNameMap)
            if isFixedNecessaryExpense(categoryName: tx.category.name, parentName: parentName) {
                fixedMap[tx.category.name, default: 0] += tx.amount.decimalValue
                fixedTotal += tx.amount.decimalValue
            }
            if isTransportExpense(categoryName: tx.category.name, parentName: parentName) {
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

    private func buildTransportSummary(transactions: [Transaction]) -> TransportSpendingSummary? {
        guard !transactions.isEmpty else { return nil }

        var taxiAmount: Decimal = 0
        var taxiCount = 0
        var publicTransitAmount: Decimal = 0
        var publicTransitCount = 0
        var longDistanceAmount: Decimal = 0
        var longDistanceCount = 0
        var totalAmount: Decimal = 0

        for tx in transactions {
            let amount = tx.amount.decimalValue
            totalAmount += amount
            switch tx.category.name {
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

    private func buildIncomeCadenceHint(incomes: [Transaction], dayCount: Int) -> String? {
        guard dayCount <= 14 else { return nil }
        let stableIncomeNames: Set<String> = ["工资", "奖金", "兼职", "报销", "房租收入", "公积金"]
        let hasStableIncome = incomes.contains { stableIncomeNames.contains($0.category.name) }
        if hasStableIncome {
            return "当前是短周期分析；工资/奖金/报销等收入可能低频发生，周收入不能直接代表收支失衡，应结合月度或滚动30天判断。"
        }
        return "当前是短周期分析；若用户是固定工资型收入，本周期收入低不应直接解读为收支失衡。"
    }

    private func parentCategoryName(for category: Category, topLevelNameMap: [UUID: String]) -> String {
        if category.isTopLevel { return category.name }
        if let parentId = category.parentId, let parentName = topLevelNameMap[parentId] {
            return parentName
        }
        return category.name
    }

    private func isFixedNecessaryExpense(categoryName: String, parentName: String) -> Bool {
        let fixedNames: Set<String> = ["房租", "房贷", "物业", "保险"]
        return fixedNames.contains(categoryName) || (parentName == "居住" && fixedNames.contains(categoryName))
    }

    private func isTransportExpense(categoryName: String, parentName: String) -> Bool {
        parentName == "交通" || ["地铁", "打车", "公交", "单车", "加油", "停车", "火车", "机票", "旅行", "过路费"].contains(categoryName)
    }

    // MARK: - Monthly Breakdown

    private func buildMonthlyBreakdown(
        transactions: [Transaction],
        start: Date,
        end: Date
    ) -> [FinanceMonthlyItem] {
        let calendar = Calendar.current
        var monthlyMap: [String: (expense: Decimal, income: Decimal)] = [:]

        for tx in transactions {
            let monthKey = Self.monthFmt.string(from: tx.date)
            var entry = monthlyMap[monthKey] ?? (0, 0)
            if tx.transactionType == .expense {
                entry.expense += tx.amount.decimalValue
            } else {
                entry.income += tx.amount.decimalValue
            }
            monthlyMap[monthKey] = entry
        }

        return monthlyMap.sorted { $0.key < $1.key }
            .prefix(12)
            .map { FinanceMonthlyItem(month: $0.key, expense: $0.value.expense, income: $0.value.income) }
    }

    // MARK: - Anomaly Detection

    private func detectAnomalies(
        expenses: [Transaction],
        averageDaily: Decimal,
        calendar: Calendar
    ) -> [String] {
        guard averageDaily > 0 else { return [] }

        let threshold = averageDaily * 2
        var dailyTotals: [Date: Decimal] = [:]
        var dailyCounts: [Date: Int] = [:]

        for tx in expenses {
            let day = calendar.startOfDay(for: tx.date)
            dailyTotals[day, default: 0] += tx.amount.decimalValue
            dailyCounts[day, default: 0] += 1
        }

        let anomalies = dailyTotals.filter { $0.value > threshold }
            .sorted { $0.value > $1.value }
            .prefix(5)

        return anomalies.map { date, amount in
            let dateStr = Self.dateFmt.string(from: date)
            let count = dailyCounts[date] ?? 1
            return "\(dateStr) 当日合计 \(count) 笔支出共 \(NumberFormatter.compactCurrency(amount))，超过日均 \(NumberFormatter.compactCurrency(threshold))"
        }
    }

    // MARK: - Budget Performance

    @MainActor
    private func buildBudgetPerformance(
        start: Date,
        endExclusive: Date,
        totalExpense: Decimal
    ) -> FinanceBudgetItem? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let budgetRepo = BudgetRepository.shared

        // 检查是否是当前自然周
        let currentWeekRange = calendar.dateInterval(of: .weekOfYear, for: today)
        if let weekRange = currentWeekRange,
           start == weekRange.start,
           endExclusive == weekRange.end {
            if let budget = budgetRepo.getTotalBudget(forAccount: UUID(), period: .week) {
                let spent = totalExpense
                let remaining = budget.amount.decimalValue - spent
                let rate = budget.amount.decimalValue > 0
                    ? Double(truncating: (spent / budget.amount.decimalValue * 100) as NSDecimalNumber)
                    : 0
                return FinanceBudgetItem(
                    budgetAmount: budget.amount.decimalValue,
                    spentAmount: spent,
                    remainingAmount: remaining,
                    utilizationRate: rate,
                    periodType: "week"
                )
            }
        }

        // 检查是否是当前自然月
        let currentMonthRange = calendar.dateInterval(of: .month, for: today)
        if let monthRange = currentMonthRange,
           start == monthRange.start,
           endExclusive == monthRange.end {
            if let budget = budgetRepo.getTotalBudget(forAccount: UUID(), period: .month) {
                let spent = totalExpense
                let remaining = budget.amount.decimalValue - spent
                let rate = budget.amount.decimalValue > 0
                    ? Double(truncating: (spent / budget.amount.decimalValue * 100) as NSDecimalNumber)
                    : 0
                return FinanceBudgetItem(
                    budgetAmount: budget.amount.decimalValue,
                    spentAmount: spent,
                    remainingAmount: remaining,
                    utilizationRate: rate,
                    periodType: "month"
                )
            }
        }

        return nil
    }

    // MARK: - Sub Category Details

    private func buildSubCategoryDetails(
        expenses: [Transaction],
        topCategoryAggregations: [CategoryAggregation]
    ) -> [SubCategoryDetail] {
        let top3 = Array(topCategoryAggregations.prefix(3))

        return top3.compactMap { agg in
            let parentId = agg.category.id
            let subExpenses = expenses.filter { $0.category.parentId == parentId }

            guard !subExpenses.isEmpty else { return nil }

            var subCategoryMap: [UUID: (name: String, amount: Decimal)] = [:]
            for tx in subExpenses {
                let catId = tx.category.id
                var entry = subCategoryMap[catId] ?? (name: tx.category.name, amount: 0)
                entry.amount += tx.amount.decimalValue
                subCategoryMap[catId] = entry
            }

            let parentTotal = subExpenses.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

            let sorted = subCategoryMap.sorted { $0.value.amount > $1.value.amount }
                .prefix(5)
                .map { _, value in
                    let pct = parentTotal > 0
                        ? Double(truncating: (value.amount / parentTotal * 100) as NSDecimalNumber)
                        : 0
                    return FinanceCategoryItem(
                        categoryName: value.name,
                        amount: value.amount,
                        percentage: pct
                    )
                }

            guard !sorted.isEmpty else { return nil }

            return SubCategoryDetail(
                parentCategoryName: agg.category.name,
                subCategories: sorted
            )
        }
    }

    // MARK: - Category Trends

    private func buildCategoryTrends(
        currentCategoryAggregations: [CategoryAggregation],
        comparisonExpenses: [Transaction],
        topLevelCategories: [Category]
    ) -> [CategoryTrendItem] {
        guard !comparisonExpenses.isEmpty else { return [] }

        let topLevelNameMap = Dictionary(
            uniqueKeysWithValues: topLevelCategories.map { ($0.id, $0.name) }
        )

        var compCategoryMap: [String: Decimal] = [:]
        for tx in comparisonExpenses {
            let parentName: String
            if tx.category.isTopLevel {
                parentName = tx.category.name
            } else if let parentId = tx.category.parentId, let name = topLevelNameMap[parentId] {
                parentName = name
            } else {
                continue
            }
            compCategoryMap[parentName, default: 0] += tx.amount.decimalValue
        }

        let currentMap = Dictionary(
            uniqueKeysWithValues: currentCategoryAggregations.map { ($0.category.name, $0.amount) }
        )

        let allNames = Set(currentMap.keys).union(Set(compCategoryMap.keys))

        return allNames.compactMap { name in
            let currentAmount = currentMap[name] ?? 0
            let previousAmount = compCategoryMap[name]

            let changePercent: Double?
            if let prev = previousAmount, prev > 0 {
                changePercent = Double(truncating: ((currentAmount - prev) / prev * 100) as NSDecimalNumber)
            } else {
                changePercent = nil
            }

            return CategoryTrendItem(
                categoryName: name,
                currentAmount: currentAmount,
                previousAmount: previousAmount,
                changePercent: changePercent
            )
        }
        .sorted { $0.currentAmount > $1.currentAmount }
    }

    // MARK: - Spending Patterns

    private func buildSpendingPatterns(
        expenses: [Transaction],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> SpendingPatterns? {
        guard !expenses.isEmpty else { return nil }

        let dayNames = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]

        var dayOfWeekTotals: [Int: Decimal] = [:]
        var dayOfWeekDates: [Int: Set<Date>] = [:]

        for tx in expenses {
            let weekday = calendar.component(.weekday, from: tx.date)
            let dayStart = calendar.startOfDay(for: tx.date)
            dayOfWeekTotals[weekday, default: 0] += tx.amount.decimalValue
            dayOfWeekDates[weekday, default: []].insert(dayStart)
        }

        let dayAverages: [(weekday: Int, average: Decimal)] = dayOfWeekTotals.compactMap { weekday, total in
            guard let dateCount = dayOfWeekDates[weekday]?.count, dateCount > 0 else { return nil }
            return (weekday, total / Decimal(dateCount))
        }

        let highestDay = dayAverages.max(by: { $0.average < $1.average }).map { best in
            DayOfWeekSpending(dayName: dayNames[best.weekday], averageAmount: best.average)
        }

        let weekdayTotal = dayOfWeekTotals
            .filter { $0.key >= 2 && $0.key <= 6 }
            .values.reduce(Decimal(0), +)
        let weekendTotal = dayOfWeekTotals
            .filter { $0.key == 1 || $0.key == 7 }
            .values.reduce(Decimal(0), +)
        let weekdayDateCount = dayOfWeekDates
            .filter { $0.key >= 2 && $0.key <= 6 }
            .values.flatMap { $0 }.count
        let weekendDateCount = dayOfWeekDates
            .filter { $0.key == 1 || $0.key == 7 }
            .values.flatMap { $0 }.count

        let weekdayVsWeekend: WeekdayWeekendComparison?
        if weekdayDateCount > 0 && weekendDateCount > 0 {
            weekdayVsWeekend = WeekdayWeekendComparison(
                weekdayAverage: weekdayTotal / Decimal(weekdayDateCount),
                weekendAverage: weekendTotal / Decimal(weekendDateCount)
            )
        } else {
            weekdayVsWeekend = nil
        }

        var categoryCountMap: [String: (count: Int, total: Decimal)] = [:]
        for tx in expenses {
            var entry = categoryCountMap[tx.category.name] ?? (count: 0, total: 0)
            entry.count += 1
            entry.total += tx.amount.decimalValue
            categoryCountMap[tx.category.name] = entry
        }

        let topFrequent = categoryCountMap.sorted { $0.value.count > $1.value.count }
            .prefix(5)
            .map { name, value in
                FrequentCategory(categoryName: name, transactionCount: value.count, totalAmount: value.total)
            }

        return SpendingPatterns(
            highestSpendingDayOfWeek: highestDay,
            weekdayVsWeekend: weekdayVsWeekend,
            topFrequentCategories: topFrequent
        )
    }
}
