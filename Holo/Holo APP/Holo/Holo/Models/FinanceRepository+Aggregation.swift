//
//  FinanceRepository+Aggregation.swift
//  Holo
//
//  日历与分析聚合查询
//

import Foundation
import CoreData

// MARK: - 统计维度筛选

/// 统计维度筛选：账户/项目切片（统计分析页下钻用）。
/// nil = 该维度不筛选取全部；两维度同时设置时取交集。
/// 所有取数函数默认 .all，既有消费点（日历/看板/Widget/AI）行为不变。
struct StatisticsScope: Equatable {
    var accountId: UUID?
    var financeProjectId: UUID?

    static let all = StatisticsScope()

    var isUnfiltered: Bool { accountId == nil && financeProjectId == nil }

    /// 维度谓词：叠加在统一统计口径（已发生 + 排对账 + 排软删）之上
    var predicates: [NSPredicate] {
        var result: [NSPredicate] = []
        if let accountId {
            result.append(NSPredicate(format: "account.id == %@", accountId as CVarArg))
        }
        if let financeProjectId {
            result.append(NSPredicate(format: "financeProjectId == %@", financeProjectId as CVarArg))
        }
        return result
    }
}

extension FinanceRepository {

    // MARK: - 日历相关查询
    
    /// 获取指定日期的所有交易（按时间降序）——明细语义，含对账调整流水
    func getTransactionsForDay(_ date: Date) async throws -> [Transaction] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let req = Transaction.fetchRequest()
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@ AND date < %@", dayStart as NSDate, dayEnd as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate(),
            NSPredicate(format: "deletedAt == nil")
        ])
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(req)
    }

    /// 获取整月的 DailySummary 字典（key = 日期 startOfDay）——收支统计口径，排除对账调整流水
    func getDailySummaries(for month: Date) async throws -> [Date: DailySummary] {
        let txns = try await getStatisticsTransactions(for: month)
        var map: [Date: (exp: Decimal, inc: Decimal, cnt: Int)] = [:]
        for tx in txns {
            let key = Calendar.current.startOfDay(for: tx.date)
            var entry = map[key] ?? (0, 0, 0)
            // 统计口径：退款笔按负支出并入当日支出（冲到账当月当日），不进收入
            if tx.statisticsType == .expense { entry.exp += tx.statisticsAmount }
            else { entry.inc += tx.statisticsAmount }
            entry.cnt += 1
            map[key] = entry
        }
        var result: [Date: DailySummary] = [:]
        for (date, entry) in map {
            result[date] = DailySummary(date: date, totalExpense: entry.exp, totalIncome: entry.inc, transactionCount: entry.cnt)
        }
        return result
    }
    
    // MARK: - 分析模块查询

    /// 获取指定时间范围内的所有交易——明细语义，含对账调整流水（日历列表、AI 明细查询用）
    func getTransactions(
        from startDate: Date,
        to endDate: Date,
        scope: StatisticsScope = .all
    ) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate(),
            NSPredicate(format: "deletedAt == nil")
        ] + scope.predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        // 调用方逐笔读分类与账户；不预取会触发每笔一次的关系惰性加载（N+1 查询），
        // 百余笔交易的区间查询会在主线程额外多出几百次小查询。
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
    }

    /// 获取指定时间范围内的统计交易——收支统计口径，排除对账调整流水
    /// （调整流水参与余额计算但不属于真实消费；所有汇总/聚合/预算/AI 统计取数必须走这个入口，
    ///  详见 docs/finance/plans/余额对账功能方案.md §2.2/§4.4）
    func getStatisticsTransactions(
        from startDate: Date,
        to endDate: Date,
        scope: StatisticsScope = .all
    ) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate(),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate(),
            NSPredicate(format: "deletedAt == nil")
        ] + scope.predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
    }

    /// 获取某月的统计交易（getStatisticsTransactions(from:to:) 的自然月便捷版）
    func getStatisticsTransactions(for month: Date) async throws -> [Transaction] {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return []
        }
        return try await getStatisticsTransactions(from: monthStart, to: monthEnd)
    }

    /// 获取指定时间范围内的分类聚合数据（收支统计口径，排除对账调整流水）
    func getCategoryAggregations(
        from startDate: Date,
        to endDate: Date,
        type: TransactionType,
        scope: StatisticsScope = .all
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate, scope: scope)
        // 统计口径：退款笔（物理 type=income）按负支出进支出侧，冲减自身分类
        let filtered = transactions.filter { $0.statisticsType == type }

        guard !filtered.isEmpty else { return [] }

        // 计算总金额
        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        // 按分类聚合
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            guard let category = tx.category else { continue }
            let catId = category.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.statisticsAmount
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: category, amount: tx.statisticsAmount, count: 1)
            }
        }

        // 转换为 CategoryAggregation 数组并按金额降序排列
        let aggregations = categoryMap.map { (_, value) -> CategoryAggregation in
            let percentage = totalAmount > 0 ? (value.amount / totalAmount) * 100 : 0
            return CategoryAggregation(
                category: value.category,
                amount: value.amount,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }.sorted { $0.amount > $1.amount }

        return aggregations
    }

    /// 获取指定时间范围内按一级分类聚合的数据（收支统计口径，排除对账调整流水）
    func getTopLevelCategoryAggregations(
        from startDate: Date,
        to endDate: Date,
        type: TransactionType,
        scope: StatisticsScope = .all
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate, scope: scope)
        // 统计口径：退款笔按负支出进支出侧，冲减所属一级分类
        let filtered = transactions.filter { $0.statisticsType == type }

        guard !filtered.isEmpty else { return [] }

        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        // 预加载一级分类
        let topLevelCategories = try await getTopLevelCategories(by: type)
        var categoryCache: [UUID: Category] = [:]
        for cat in topLevelCategories {
            categoryCache[cat.id] = cat
        }

        // 按一级分类聚合（如果是二级分类则归入父分类）
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        // 父一级不在活分类缓存（软删/悬空）的孤儿子分类：会在此冒充一级混入饼图
        // 第一层。CategoryOrphanRepair 负责把数据拉回正常态，这里留痕供异常排查，
        // 按分类去重避免热路径刷屏。
        var orphanFallbackCategoryNames: Set<String> = []
        for tx in filtered {
            guard let txCategory = tx.category else { continue }
            // 获取一级分类
            let topCategory: Category
            if txCategory.isTopLevel {
                topCategory = txCategory
            } else if let parentId = txCategory.parentId {
                // 从缓存中查找父分类
                if let parent = categoryCache[parentId] {
                    topCategory = parent
                } else {
                    orphanFallbackCategoryNames.insert(txCategory.name ?? "-")
                    topCategory = txCategory
                }
            } else {
                topCategory = txCategory
            }

            let catId = topCategory.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.statisticsAmount
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: topCategory, amount: tx.statisticsAmount, count: 1)
            }
        }

        let aggregations = categoryMap.map { (_, value) -> CategoryAggregation in
            let percentage = totalAmount > 0 ? (value.amount / totalAmount) * 100 : 0
            return CategoryAggregation(
                category: value.category,
                amount: value.amount,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }.sorted { $0.amount > $1.amount }

        if !orphanFallbackCategoryNames.isEmpty {
            NSLog("统计分析：孤儿子分类冒充一级 %d 个（%@），等待 CategoryOrphanRepair 修复数据",
                  orphanFallbackCategoryNames.count,
                  orphanFallbackCategoryNames.sorted().joined(separator: "、"))
        }

        return aggregations
    }

    /// 获取指定一级分类下所有二级分类的聚合数据（用于下钻；收支统计口径，排除对账调整流水）
    func getSubCategoryAggregations(
        parentId: UUID,
        from startDate: Date,
        to endDate: Date,
        scope: StatisticsScope = .all
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate, scope: scope)

        // 筛选属于该一级分类的交易
        let filtered = transactions.filter { tx in
            guard let category = tx.category else { return false }
            if category.isTopLevel {
                return category.id == parentId
            } else {
                return category.parentId == parentId
            }
        }

        guard !filtered.isEmpty else { return [] }

        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        // 按二级分类聚合（退款笔取负值冲减；普通收入误挂支出分类时维持现状行为）
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            guard let cat = tx.category else { continue }
            let catId = cat.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.statisticsAmount
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: cat, amount: tx.statisticsAmount, count: 1)
            }
        }

        let aggregations = categoryMap.map { (_, value) -> CategoryAggregation in
            let percentage = totalAmount > 0 ? (value.amount / totalAmount) * 100 : 0
            return CategoryAggregation(
                category: value.category,
                amount: value.amount,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }.sorted { $0.amount > $1.amount }

        return aggregations
    }

    // MARK: - 账户/项目维度聚合（统计页排行卡）

    /// 时间范围内各账户的收支聚合（支出口径含退款负冲，与汇总卡一致）。
    /// 返回本期有统计交易的全部账户（含归档），按支出降序；零支出账户由 UI 层决定是否隐藏。
    func getAccountAggregations(
        from startDate: Date,
        to endDate: Date,
        scope: StatisticsScope = .all
    ) async throws -> [AccountAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate, scope: scope)

        var map: [UUID: (account: Account, expense: Decimal, income: Decimal, count: Int)] = [:]
        for tx in transactions {
            guard let account = tx.account else { continue }
            let key = account.id
            if var entry = map[key] {
                if tx.statisticsType == .expense {
                    entry.expense += tx.statisticsAmount
                } else {
                    entry.income += tx.statisticsAmount
                }
                entry.count += 1
                map[key] = entry
            } else {
                map[key] = (
                    account: account,
                    expense: tx.statisticsType == .expense ? tx.statisticsAmount : 0,
                    income: tx.statisticsType == .income ? tx.statisticsAmount : 0,
                    count: 1
                )
            }
        }

        let totalExpense = transactions
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        return map.values.map { value in
            let percentage = totalExpense > 0 ? (value.expense / totalExpense) * 100 : 0
            return AccountAggregation(
                account: value.account,
                expense: value.expense,
                income: value.income,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }
        .sorted { $0.expense > $1.expense }
    }

    /// 时间范围内各财务项目的收支聚合（支出侧含退款负冲，statisticsType 口径）。
    /// 项目已删除（查不到对象）的挂靠交易不计入；按支出降序。
    func getFinanceProjectAggregations(
        from startDate: Date,
        to endDate: Date,
        scope: StatisticsScope = .all
    ) async throws -> [FinanceProjectAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate, scope: scope)
        let expenseTxns = transactions.filter { $0.statisticsType == .expense }
        let totalExpense = expenseTxns.reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        var map: [UUID: (expense: Decimal, income: Decimal, count: Int)] = [:]
        for tx in transactions {
            guard let projectId = tx.financeProjectId else { continue }
            let entry = map[projectId] ?? (expense: 0, income: 0, count: 0)
            if tx.statisticsType == .expense {
                map[projectId] = (entry.expense + tx.statisticsAmount, entry.income, entry.count + 1)
            } else {
                map[projectId] = (entry.expense, entry.income + tx.statisticsAmount, entry.count + 1)
            }
        }
        guard !map.isEmpty else { return [] }

        // 挂靠 id → 项目对象（软删/硬删的项目丢弃，展示无名项目无意义）
        let projectRequest = FinanceProject.fetchRequest()
        projectRequest.predicate = NSPredicate(format: "deletedAt == nil")
        let liveProjects = (try? context.fetch(projectRequest)) ?? []
        var projectById: [UUID: FinanceProject] = [:]
        for project in DuplicateRowFilter.deduplicatingCopies(liveProjects) {
            projectById[project.id] = project
        }

        return map.compactMap { projectId, value in
            guard let project = projectById[projectId] else { return nil }
            let percentage = totalExpense > 0 ? (value.expense / totalExpense) * 100 : 0
            return FinanceProjectAggregation(
                project: project,
                expense: value.expense,
                income: value.income,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }
        .sorted { $0.expense > $1.expense }
    }

}
