//
//  FinanceRepository+Aggregation.swift
//  Holo
//
//  日历与分析聚合查询
//

import Foundation
import CoreData

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
            FinanceTransactionOccurrencePolicy.occurredPredicate()
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
            if tx.transactionType == .expense { entry.exp += tx.amount.decimalValue }
            else { entry.inc += tx.amount.decimalValue }
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
    func getTransactions(from startDate: Date, to endDate: Date) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate()
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        // 调用方逐笔读分类与账户；不预取会触发每笔一次的关系惰性加载（N+1 查询），
        // 百余笔交易的区间查询会在主线程额外多出几百次小查询。
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return try context.fetch(request)
    }

    /// 获取指定时间范围内的统计交易——收支统计口径，排除对账调整流水
    /// （调整流水参与余额计算但不属于真实消费；所有汇总/聚合/预算/AI 统计取数必须走这个入口，
    ///  详见 docs/finance/plans/余额对账功能方案.md §2.2/§4.4）
    func getStatisticsTransactions(from startDate: Date, to endDate: Date) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate(),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate()
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return try context.fetch(request)
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
        type: TransactionType
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate)
        let filtered = transactions.filter { $0.transactionType == type }

        guard !filtered.isEmpty else { return [] }

        // 计算总金额
        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        // 按分类聚合
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            guard let category = tx.category else { continue }
            let catId = category.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.amount.decimalValue
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: category, amount: tx.amount.decimalValue, count: 1)
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
        type: TransactionType
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate)
        let filtered = transactions.filter { $0.transactionType == type }

        guard !filtered.isEmpty else { return [] }

        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        // 预加载一级分类
        let topLevelCategories = try await getTopLevelCategories(by: type)
        var categoryCache: [UUID: Category] = [:]
        for cat in topLevelCategories {
            categoryCache[cat.id] = cat
        }

        // 按一级分类聚合（如果是二级分类则归入父分类）
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
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
                    topCategory = txCategory
                }
            } else {
                topCategory = txCategory
            }

            let catId = topCategory.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.amount.decimalValue
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: topCategory, amount: tx.amount.decimalValue, count: 1)
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

    /// 获取指定一级分类下所有二级分类的聚合数据（用于下钻；收支统计口径，排除对账调整流水）
    func getSubCategoryAggregations(
        parentId: UUID,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getStatisticsTransactions(from: startDate, to: endDate)

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

        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        // 按二级分类聚合
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            guard let cat = tx.category else { continue }
            let catId = cat.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.amount.decimalValue
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: cat, amount: tx.amount.decimalValue, count: 1)
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

}
