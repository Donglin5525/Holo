//
//  HoloFinanceDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task #34 生产财务数据源
//  包裹真实 FinanceRepository，聚合本期/基线消费（晚间餐饮频次 / 分类次数 / 金额），
//  转为 FinanceTool 中性结构。依赖 Core Data，仅随 app 编译，不进入 standalone 测试。
//

import Foundation

struct HoloDefaultFinanceDataSource: HoloFinanceDataSource {

    func balanceDiagnosis() async -> HoloFinanceBalanceDiagnosis? {
        let repository = FinanceRepository.shared
        guard let transactions = try? await repository.getAllTransactions() else { return nil }
        let accountMetadata = await MainActor.run { () -> (count: Int, openingBalance: Double) in
            let accounts = repository.getAccounts(includeArchived: false)
            return (
                accounts.count,
                accounts.reduce(0) { $0 + $1.initialBalance.doubleValue }
            )
        }
        let entries = transactions.map { transaction in
            HoloFinanceBalanceEntry(
                amount: transaction.amount.doubleValue,
                isIncome: transaction.transactionType == .income,
                expenseSource: transaction.spendingProjectId == nil ? .manual : .recurring,
                categoryName: transaction.category?.name ?? "未分类",
                excerpt: Self.sampleExcerpt(for: transaction)
            )
        }
        return HoloFinanceBalanceCalculator.calculate(
            activeAccountCount: accountMetadata.count,
            openingBalance: accountMetadata.openingBalance,
            entries: entries
        )
    }

    func queryRows(timeRange: HoloAgentTimeRange?, parameters: [String: String]) async -> [HoloQueryRow] {
        let calendar = Calendar.current
        let resolved = HoloAgentHistoricalTimePolicy.resolve(timeRange, calendar: calendar)
        guard !resolved.isEntirelyFuture else { return [] }
        let effectiveRange = resolved.effectiveRange
        let end = effectiveRange?.end ?? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date())
        let start = effectiveRange?.start ?? (calendar.date(byAdding: .day, value: -30, to: end) ?? end)
        guard let transactions = try? await FinanceRepository.shared.getTransactions(from: start, to: end) else { return [] }
        return transactions.map { tx in
            let text = [tx.note, tx.remark, tx.tags?.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
            return HoloQueryRow(
                id: tx.id.uuidString,
                occurredAt: tx.date,
                fields: [
                    "date": .date(tx.date),
                    "amount": .number(tx.amount.doubleValue),
                    "type": .text(tx.transactionType == .expense ? "expense" : "income"),
                    "category": .text(tx.category?.name ?? "未分类"),
                    "account": .text(tx.account?.name ?? "未指定账户"),
                    "text": .text(text)
                ],
                excerpt: Self.sampleExcerpt(for: tx)
            )
        }
    }

    func snapshot(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloFinanceToolRecord? {
        let repo = FinanceRepository.shared
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let defaultCurrentEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
        let resolvedCurrent = HoloAgentHistoricalTimePolicy.resolve(timeRange, calendar: calendar)
        guard !resolvedCurrent.isEntirelyFuture else { return nil }
        let effectiveCurrent = Self.financeCycleAligned(resolvedCurrent.effectiveRange, calendar: calendar)
        let currentEnd = effectiveCurrent?.end ?? defaultCurrentEnd
        let currentStart = effectiveCurrent?.start
            ?? (calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart)
        let resolvedBaseline = HoloAgentHistoricalTimePolicy.resolve(baseline, calendar: calendar)
        guard !resolvedBaseline.isEntirelyFuture else { return nil }
        let effectiveBaseline = Self.financeCycleAligned(resolvedBaseline.effectiveRange, calendar: calendar)
        let baselineEnd = effectiveBaseline?.end ?? currentStart
        let baselineStart = effectiveBaseline?.start
            ?? (calendar.date(byAdding: .day, value: -14, to: baselineEnd) ?? baselineEnd)
        let currentTransactions: [Transaction]
        let baselineTransactions: [Transaction]
        do {
            currentTransactions = try await repo.getTransactions(from: currentStart, to: currentEnd)
            baselineTransactions = try await repo.getTransactions(from: baselineStart, to: baselineEnd)
        } catch {
            return nil
        }
        let currentRange = HoloAgentTimeRange(label: effectiveCurrent?.label ?? "本期", start: currentStart, end: currentEnd)
        let baselineRange = HoloAgentTimeRange(label: effectiveBaseline?.label ?? "对比期", start: baselineStart, end: baselineEnd)
        let financeMetadata = await MainActor.run { () -> (HoloFinanceBudgetSnapshot?, HoloFinanceAccountSnapshot) in
            let budgetRepository = BudgetRepository.shared
            let financeRepository = FinanceRepository.shared
            let globalBudget = budgetRepository.computeGlobalTotalBudgetStatus(period: .month)
            let warningCategories = budgetRepository
                .getWarningCategoryBudgets(period: .month)
                .map(\.categoryName)
            // 全量分类预算明细：不限定 progress >= 0.8，收集每类"预算 vs 实际"对比，
            // 为"哪类超预算 / 为什么超支"归因提供预算口径原料。
            // 已花金额取预算周期口径（computeBudgetStatus 内按预算当前周期统计），与预算对齐。
            let accounts = financeRepository.getAccounts(includeArchived: false)
            var categoryBudgets: [HoloFinanceCategoryBudget] = []
            for account in accounts {
                let categoryBudgetList = budgetRepository.getCategoryBudgets(forAccount: account.id)
                for budget in categoryBudgetList {
                    guard let status = budgetRepository.computeBudgetStatus(budget: budget) else { continue }
                    let category = budgetRepository.findCategory(by: budget.categoryId)
                    categoryBudgets.append(HoloFinanceCategoryBudget(
                        categoryName: category?.name ?? "未知分类",
                        budgetAmount: Self.double(status.budgetAmount),
                        spentAmount: Self.double(status.spentAmount),
                        remainingAmount: Self.double(status.remainingAmount),
                        progress: status.progress,
                        isOverBudget: status.isOverBudget
                    ))
                }
            }
            let netWorth = financeRepository.getTotalNetWorth()
            let defaultAccount = financeRepository.getDefaultAccountSync()
            let budgetSnapshot = globalBudget.map {
                HoloFinanceBudgetSnapshot(
                    totalAmount: Self.double($0.totalBudgetAmount),
                    spentAmount: Self.double($0.totalSpentAmount),
                    remainingAmount: Self.double($0.totalRemainingAmount),
                    progress: $0.progress,
                    remainingDays: $0.remainingDays,
                    warningCategoryNames: warningCategories,
                    categoryBudgets: categoryBudgets
                )
            }
            return (
                budgetSnapshot,
                HoloFinanceAccountSnapshot(
                    activeAccountCount: accounts.count,
                    assets: Self.double(netWorth.assets),
                    liabilities: Self.double(netWorth.liabilities),
                    netWorth: Self.double(netWorth.netWorth),
                    defaultAccountName: defaultAccount?.name,
                    creditCards: accounts.compactMap { account in
                        guard account.hasBillingCycle, let billingDay = account.billingDayInt else { return nil }
                        return HoloFinanceCreditCard(
                            name: account.name,
                            billingDay: billingDay,
                            dueDay: account.dueDayInt,
                            creditLimit: account.creditLimitDecimal.map { Self.double($0) }
                        )
                    }
                )
            )
        }
        let keyword = Self.keyword(from: parameters)
        let currentKeyword = Self.keywordSummary(currentTransactions, keyword: keyword)
        let baselineKeyword = Self.keywordSummary(baselineTransactions, keyword: keyword)
        return HoloFinanceToolRecord(
            nighttimeMealCurrent: Self.nighttimeMealCount(currentTransactions),
            nighttimeMealBaseline: Self.nighttimeMealCount(baselineTransactions),
            categoryCounts: Self.categoryCounts(currentTransactions),
            categoryAmounts: Self.categoryAmounts(currentTransactions),
            totalCurrentAmount: Self.totalExpense(currentTransactions),
            totalBaselineAmount: Self.totalExpense(baselineTransactions),
            transactionCount: Self.expenseCount(currentTransactions),
            currentRange: currentRange,
            baselineRange: baselineRange,
            keyword: keyword.isEmpty ? nil : keyword,
            keywordCurrentCount: currentKeyword.count,
            keywordBaselineCount: baselineKeyword.count,
            keywordCurrentAmount: currentKeyword.amount,
            keywordBaselineAmount: baselineKeyword.amount,
            keywordSampleExcerpts: currentKeyword.samples,
            topExpenseExcerpts: Self.topExpenseSamples(currentTransactions),
            budget: financeMetadata.0,
            account: financeMetadata.1
        )
    }

    /// 晚间（22:00–06:00）餐饮类支出笔数。
    private static func nighttimeMealCount(_ txs: [Transaction]) -> Int {
        let mealKeywords = ["餐", "食", "吃", "外卖", "宵夜", "饭", "饮"]
        let calendar = Calendar.current
        return txs.filter { tx in
            guard tx.transactionType == .expense else { return false }
            let hour = calendar.component(.hour, from: tx.date)
            let isNighttime = hour >= 22 || hour < 6
            let name = tx.category?.name ?? ""
            return isNighttime && mealKeywords.contains { name.contains($0) }
        }.count
    }

    /// 本期各分类支出笔数。
    private static func categoryCounts(_ txs: [Transaction]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tx in txs where tx.transactionType == .expense {
            let name = tx.category?.name ?? "未分类"
            counts[name, default: 0] += 1
        }
        return counts
    }

    /// 本期各分类支出金额。
    private static func categoryAmounts(_ txs: [Transaction]) -> [String: Double] {
        var amounts: [String: Double] = [:]
        for tx in txs where tx.transactionType == .expense {
            let name = tx.category?.name ?? "未分类"
            amounts[name, default: 0] += tx.amount.doubleValue
        }
        return amounts
    }

    private static func expenseCount(_ txs: [Transaction]) -> Int {
        txs.filter { $0.transactionType == .expense }.count
    }

    private static func totalExpense(_ txs: [Transaction]) -> Double {
        txs.filter { $0.transactionType == .expense }.reduce(0.0) { $0 + $1.amount.doubleValue }
    }

    private static func keyword(from parameters: [String: String]) -> String {
        (parameters["keyword"] ?? parameters["term"] ?? parameters["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keywordSummary(_ txs: [Transaction], keyword: String) -> (count: Int, amount: Double, samples: [String]) {
        guard !keyword.isEmpty else { return (0, 0, []) }
        let matches = txs.filter { tx in
            guard tx.transactionType == .expense else { return false }
            return searchableText(for: tx).localizedCaseInsensitiveContains(keyword)
        }
        let amount = matches.reduce(0.0) { $0 + $1.amount.doubleValue }
        let samples = matches.prefix(5).map(sampleExcerpt)
        return (matches.count, amount, samples)
    }

    private static func topExpenseSamples(_ txs: [Transaction]) -> [String] {
        txs
            .filter { $0.transactionType == .expense }
            .sorted { $0.amount.doubleValue > $1.amount.doubleValue }
            .prefix(5)
            .map(sampleExcerpt)
    }

    private static func searchableText(for tx: Transaction) -> String {
        [
            tx.note,
            tx.remark,
            tx.category?.name,
            tx.tags?.joined(separator: " ")
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    nonisolated private static func sampleExcerpt(for tx: Transaction) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let date = formatter.string(from: tx.date)
        let category = tx.category?.name ?? "未分类"
        let note = [tx.note, tx.remark]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "无备注"
        let amount = tx.amount.doubleValue
        let amountText = amount.rounded() == amount ? String(format: "%.0f", amount) : String(format: "%.2f", amount)
        return "\(date) \(category) \(note) -¥\(amountText)"
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// 财务域「月」语义对齐记账周期（与统计页同一口径）。
    /// 仅白名单命中「本月/这个月/月至今/上月/上个月」时换算（「近一个月」等滚动窗口语义不动），
    /// 其他域的时间语义不受影响（此函数只在财务数据源内调用）。
    private static func financeCycleAligned(_ range: HoloAgentTimeRange?, calendar: Calendar) -> HoloAgentTimeRange? {
        guard let range else { return nil }
        let label = range.label
        let isPrevious = label.contains("上个月") || label.contains("上月")
        let isCurrentMonth = label.contains("本月") || label.contains("这个月") || label.contains("月至今")
        guard isPrevious || isCurrentMonth else { return range }

        let startDay = FinancePeriodSettings.storedBillingCycleStartDay
        let today = calendar.startOfDay(for: Date())
        if isPrevious {
            let prev = BillingCycleCalculator.previousCycleRange(startDay: startDay, reference: today, calendar: calendar)
            let prevEnd = calendar.date(byAdding: .day, value: -1, to: prev.end) ?? today
            return HoloAgentTimeRange(label: "\(label)·记账周期", start: prev.start, end: prevEnd)
        }
        let current = BillingCycleCalculator.currentCycleRange(startDay: startDay, reference: today, calendar: calendar)
        return HoloAgentTimeRange(label: "\(label)·记账周期", start: current.start, end: today)
    }
}
