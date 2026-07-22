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

    func queryRows(timeRange: HoloAgentTimeRange?, parameters: [String: String]) async -> [HoloQueryRow] {
        await queryRowsRead(timeRange: timeRange, parameters: parameters).value
    }

    func queryRowsRead(timeRange: HoloAgentTimeRange?, parameters: [String: String]) async -> HoloDataSourceRead<[HoloQueryRow]> {
        let calendar = Calendar.current
        let end = timeRange?.end ?? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date())
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -30, to: end) ?? end)
        let transactions: [Transaction]
        do {
            transactions = try await FinanceRepository.shared.getTransactions(from: start, to: end)
        } catch {
            return HoloDataSourceRead(value: [], status: .unavailable, warning: "财务交易读取失败：\(error.localizedDescription)")
        }
        let rows = transactions.map { tx in
            let isExpense = tx.transactionType == .expense
            let amount = tx.amount.doubleValue
            return HoloQueryRow(
                id: tx.id.uuidString,
                occurredAt: tx.date,
                fields: [
                    "date": .date(tx.date),
                    "amount": .number(amount),
                    "signedAmount": .number(isExpense ? -amount : amount),
                    "expenseAmount": .number(isExpense ? amount : 0),
                    "incomeAmount": .number(isExpense ? 0 : amount),
                    "type": .text(isExpense ? "expense" : "income"),
                    "category": .text(tx.category?.name ?? "未分类")
                ],
                excerpt: Self.sampleExcerpt(for: tx)
            )
        }
        return .loaded(rows, totalCount: rows.count)
    }

    func snapshot(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloFinanceToolRecord? {
        await snapshotRead(timeRange: timeRange, baseline: baseline, parameters: parameters).value
    }

    func snapshotRead(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloDataSourceRead<HoloFinanceToolRecord?> {
        let repo = FinanceRepository.shared
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let defaultCurrentEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
        let currentEnd = timeRange?.end ?? defaultCurrentEnd
        let currentStart = timeRange?.start
            ?? (calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart)
        let baselineEnd = baseline?.end ?? currentStart
        let baselineStart = baseline?.start
            ?? (calendar.date(byAdding: .day, value: -14, to: baselineEnd) ?? baselineEnd)
        let currentTransactions: [Transaction]
        let baselineTransactions: [Transaction]
        do {
            currentTransactions = try await repo.getTransactions(from: currentStart, to: currentEnd)
            baselineTransactions = try await repo.getTransactions(from: baselineStart, to: baselineEnd)
        } catch {
            return HoloDataSourceRead(value: nil, status: .unavailable, warning: "财务快照读取失败：\(error.localizedDescription)")
        }
        let currentRange = HoloAgentTimeRange(label: timeRange?.label ?? "本期", start: currentStart, end: currentEnd)
        let baselineRange = HoloAgentTimeRange(label: baseline?.label ?? "对比期", start: baselineStart, end: baselineEnd)
        let financeMetadata = await MainActor.run { () -> (HoloFinanceBudgetSnapshot?, HoloFinanceAccountSnapshot) in
            let budgetRepository = BudgetRepository.shared
            let financeRepository = FinanceRepository.shared
            let globalBudget = budgetRepository.computeGlobalTotalBudgetStatus(period: .month)
            let warningCategories = budgetRepository
                .getWarningCategoryBudgets(period: .month)
                .map(\.categoryName)
            let accounts = financeRepository.getAccounts(includeArchived: false)
            let netWorth = financeRepository.getTotalNetWorth()
            let budgetSnapshot = globalBudget.map {
                HoloFinanceBudgetSnapshot(
                    totalAmount: Self.double($0.totalBudgetAmount),
                    spentAmount: Self.double($0.totalSpentAmount),
                    remainingAmount: Self.double($0.totalRemainingAmount),
                    progress: $0.progress,
                    remainingDays: $0.remainingDays,
                    warningCategoryNames: warningCategories
                )
            }
            return (
                budgetSnapshot,
                HoloFinanceAccountSnapshot(
                    activeAccountCount: accounts.count,
                    assets: Self.double(netWorth.assets),
                    liabilities: Self.double(netWorth.liabilities),
                    netWorth: Self.double(netWorth.netWorth)
                )
            )
        }
        let keyword = Self.keyword(from: parameters)
        let currentKeyword = Self.keywordSummary(currentTransactions, keyword: keyword)
        let baselineKeyword = Self.keywordSummary(baselineTransactions, keyword: keyword)
        let record = HoloFinanceToolRecord(
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
        return HoloDataSourceRead(value: record, status: .success)
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
        var amounts: [String: Decimal] = [:]
        for tx in txs where tx.transactionType == .expense {
            let name = tx.category?.name ?? "未分类"
            amounts[name, default: 0] += tx.amount.decimalValue
        }
        return amounts.mapValues(double)
    }

    private static func expenseCount(_ txs: [Transaction]) -> Int {
        txs.filter { $0.transactionType == .expense }.count
    }

    private static func totalExpense(_ txs: [Transaction]) -> Double {
        double(
            txs.filter { $0.transactionType == .expense }
                .reduce(Decimal.zero) { $0 + $1.amount.decimalValue }
        )
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
        let amount = double(matches.reduce(Decimal.zero) { $0 + $1.amount.decimalValue })
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
        let amount = tx.amount.doubleValue
        let amountText = amount.rounded() == amount ? String(format: "%.0f", amount) : String(format: "%.2f", amount)
        return "\(date) \(category) -¥\(amountText)"
    }

    nonisolated private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
