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
    
    /// 获取指定日期的所有交易（按时间降序）
    func getTransactionsForDay(_ date: Date) async throws -> [Transaction] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let req = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@", dayStart as NSDate, dayEnd as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(req)
    }
    
    /// 获取整月的 DailySummary 字典（key = 日期 startOfDay）
    func getDailySummaries(for month: Date) async throws -> [Date: DailySummary] {
        let txns = try await getTransactions(for: month)
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

    /// 获取指定时间范围内的所有交易
    func getTransactions(from startDate: Date, to endDate: Date) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try context.fetch(request)
    }

    /// 获取指定时间范围内的分类聚合数据
    func getCategoryAggregations(
        from startDate: Date,
        to endDate: Date,
        type: TransactionType
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getTransactions(from: startDate, to: endDate)
        let filtered = transactions.filter { $0.transactionType == type }

        guard !filtered.isEmpty else { return [] }

        // 计算总金额
        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        // 按分类聚合
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            let catId = tx.category.id
            if var entry = categoryMap[catId] {
                entry.amount += tx.amount.decimalValue
                entry.count += 1
                categoryMap[catId] = entry
            } else {
                categoryMap[catId] = (category: tx.category, amount: tx.amount.decimalValue, count: 1)
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

    /// 获取指定时间范围内按一级分类聚合的数据
    func getTopLevelCategoryAggregations(
        from startDate: Date,
        to endDate: Date,
        type: TransactionType
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getTransactions(from: startDate, to: endDate)
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
            // 获取一级分类
            let topCategory: Category
            if tx.category.isTopLevel {
                topCategory = tx.category
            } else if let parentId = tx.category.parentId {
                // 从缓存中查找父分类
                if let parent = categoryCache[parentId] {
                    topCategory = parent
                } else {
                    topCategory = tx.category
                }
            } else {
                topCategory = tx.category
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

    /// 获取指定一级分类下所有二级分类的聚合数据（用于下钻）
    func getSubCategoryAggregations(
        parentId: UUID,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [CategoryAggregation] {
        let transactions = try await getTransactions(from: startDate, to: endDate)

        // 筛选属于该一级分类的交易
        let filtered = transactions.filter { tx in
            if tx.category.isTopLevel {
                return tx.category.id == parentId
            } else {
                return tx.category.parentId == parentId
            }
        }

        guard !filtered.isEmpty else { return [] }

        let totalAmount = filtered.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        // 按二级分类聚合
        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in filtered {
            let cat = tx.category
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
