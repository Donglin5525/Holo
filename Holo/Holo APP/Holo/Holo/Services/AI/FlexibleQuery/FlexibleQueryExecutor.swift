//
//  FlexibleQueryExecutor.swift
//  Holo
//
//  灵活查询执行器 + FinanceQueryTool
//  后台 DTO 查询策略，不阻塞主线程
//

import Foundation
import CoreData
import os.log

// MARK: - Executor

final class FlexibleQueryExecutor {
    private let logger = Logger(subsystem: "com.holo.app", category: "FlexibleQueryExecutor")

    /// 执行 Query Plan，返回结构化结果
    func execute(_ plan: FlexibleQueryPlan) async throws -> FlexibleQueryResult {
        // 后台 context 执行查询
        let rawResults: [FlexibleTransactionDTO] = try await CoreDataStack.shared.performBackgroundTask { context in
            try Self.fetchTransactions(plan: plan, context: context)
        }

        // 无约束检查
        if rawResults.isEmpty {
            return Self.buildEmptyResult(plan: plan)
        }

        // 排序
        let sorted = Self.applySort(rawResults: rawResults, plan: plan)

        // limit
        let limited: [FlexibleTransactionDTO]
        if let limit = plan.limit {
            limited = Array(sorted.prefix(limit))
        } else {
            limited = Array(sorted.prefix(20))
        }

        // 构建 evidence
        let evidences = limited.map { Self.toEvidence($0) }

        // 计算 summary
        let allMatched = sorted
        let summary = Self.buildSummary(evidences: allMatched)

        // 计算结果
        let calcResult = Self.calculate(plan: plan, evidences: allMatched)

        // 空结果检查（排序+limit 后可能为空）
        if evidences.isEmpty {
            return Self.buildEmptyResult(plan: plan)
        }

        return FlexibleQueryResult(
            plan: plan,
            status: .success,
            summary: summary,
            matchedTransactions: evidences,
            calculationResult: calcResult,
            emptyReason: nil,
            followUpSuggestion: nil
        )
    }

    // MARK: - Fetch (Background Context)

    /// 后台 context 粗筛 + DTO 多字段关键词过滤
    private static func fetchTransactions(
        plan: FlexibleQueryPlan,
        context: NSManagedObjectContext
    ) throws -> [FlexibleTransactionDTO] {
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest() as! NSFetchRequest<Transaction>

        // 粗筛 predicate：type + date + amount
        var predicates: [NSPredicate] = []

        // type
        if let typeFilter = plan.filters.type, typeFilter != .any {
            predicates.append(NSPredicate(format: "type == %@", typeFilter == .expense ? "expense" : "income"))
        }

        // date range
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let startStr = plan.filters.startDate, let startDate = df.date(from: startStr) {
            predicates.append(NSPredicate(format: "date >= %@", startDate as NSDate))
        }
        if let endStr = plan.filters.endDate, let endDate = df.date(from: endStr) {
            // 包含当天
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
            predicates.append(NSPredicate(format: "date < %@", endOfDay as NSDate))
        }

        // amount 粗筛
        if let amountGT = plan.filters.amountGreaterThan {
            predicates.append(NSPredicate(format: "amount > %@", NSDecimalNumber(decimal: amountGT)))
        }
        if let amountGTE = plan.filters.amountGreaterThanOrEqual {
            predicates.append(NSPredicate(format: "amount >= %@", NSDecimalNumber(decimal: amountGTE)))
        }
        if let amountLT = plan.filters.amountLessThan {
            predicates.append(NSPredicate(format: "amount < %@", NSDecimalNumber(decimal: amountLT)))
        }
        if let amountLTE = plan.filters.amountLessThanOrEqual {
            predicates.append(NSPredicate(format: "amount <= %@", NSDecimalNumber(decimal: amountLTE)))
        }
        if let amountEQ = plan.filters.amountEqual {
            predicates.append(NSPredicate(format: "amount == %@", NSDecimalNumber(decimal: amountEQ)))
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        // 按日期降序预排序（后续会再排序）
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        // 粗筛上限 200
        request.fetchLimit = 200

        let transactions = try context.fetch(request)

        // 批量加载分类名和父分类名缓存
        let categoryCache = buildCategoryCache(context: context)

        // DTO 映射 + 关键词过滤
        let dtos = transactions.compactMap { tx -> FlexibleTransactionDTO? in
            let categoryObj = tx.category
            let catName = categoryObj?.name
            var parentCatName: String? = nil
            if let parentId = categoryObj?.parentId {
                parentCatName = categoryCache[parentId]
            }

            return FlexibleTransactionDTO(
                id: tx.id,
                amount: tx.amount as Decimal,
                type: tx.type,
                date: tx.date,
                note: tx.note,
                remark: tx.remark,
                tags: tx.tags ?? [],
                categoryName: catName,
                parentCategoryName: parentCatName,
                aiCandidate: tx.aiCandidate,
                accountId: tx.account?.id
            )
        }

        // 关键词 + 分类 + 排除词过滤（在 DTO 上）
        return applyKeywordFilter(dtos: dtos, filters: plan.filters)
    }

    // MARK: - Category Cache

    private static func buildCategoryCache(context: NSManagedObjectContext) -> [UUID: String] {
        let request: NSFetchRequest<Category> = Category.fetchRequest() as! NSFetchRequest<Category>
        guard let categories = try? context.fetch(request) else { return [:] }
        var cache: [UUID: String] = [:]
        for cat in categories {
            cache[cat.id] = cat.name
        }
        return cache
    }

    // MARK: - Keyword Filter

    private static func applyKeywordFilter(
        dtos: [FlexibleTransactionDTO],
        filters: FinanceQueryFilters
    ) -> [FlexibleTransactionDTO] {
        let keywords = filters.keywords
        let excludedKeywords = filters.excludedKeywords
        let categoryNames = filters.categoryNames
        let accountNames = filters.accountNames

        return dtos.filter { dto in
            // 排除词
            if !excludedKeywords.isEmpty {
                let allText = combinedText(dto: dto, filters: filters)
                for ex in excludedKeywords {
                    if allText.contains(ex) { return false }
                }
            }

            // 账户名过滤
            if !accountNames.isEmpty {
                // 账户名匹配需要在 DTO 中有账户名，MVP 先跳过
            }

            // 分类精确匹配
            if !categoryNames.isEmpty {
                let catMatch = categoryNames.contains(where: { cn in
                    dto.categoryName == cn || dto.parentCategoryName == cn
                })
                // 有分类条件但分类不匹配时，如果有其他条件也允许通过
                if catMatch { return true }
                if keywords.isEmpty { return false }
            }

            // 关键词子串匹配
            if !keywords.isEmpty {
                let allText = combinedText(dto: dto, filters: filters)
                return keywords.contains(where: { kw in allText.contains(kw) })
            }

            // 无关键词也无分类名，只有金额/日期/类型过滤（已在粗筛中完成）
            return true
        }
    }

    /// 组合可搜索文本
    private static func combinedText(dto: FlexibleTransactionDTO, filters: FinanceQueryFilters) -> String {
        var parts: [String] = []
        if filters.includeNote, let note = dto.note { parts.append(note) }
        if filters.includeRemark, let remark = dto.remark { parts.append(remark) }
        if filters.includeTags { parts.append(contentsOf: dto.tags) }
        if filters.includeCategory {
            if let cn = dto.categoryName { parts.append(cn) }
            if let pcn = dto.parentCategoryName { parts.append(pcn) }
        }
        parts.append(dto.aiCandidate ?? "")
        return parts.joined(separator: " ")
    }

    // MARK: - Sort

    private static func applySort(rawResults: [FlexibleTransactionDTO], plan: FlexibleQueryPlan) -> [FlexibleTransactionDTO] {
        guard let sort = plan.sort else {
            // 默认按日期降序
            return rawResults.sorted { $0.date > $1.date }
        }

        switch sort.field {
        case .date:
            return sort.direction == .desc
                ? rawResults.sorted { $0.date > $1.date }
                : rawResults.sorted { $0.date < $1.date }
        case .amount:
            return sort.direction == .desc
                ? rawResults.sorted { $0.amount > $1.amount }
                : rawResults.sorted { $0.amount < $1.amount }
        }
    }

    // MARK: - Evidence

    private static func toEvidence(_ dto: FlexibleTransactionDTO) -> FlexibleTransactionEvidence {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"

        // 匹配字段推断
        var matched: [String] = []
        if dto.note != nil { matched.append("note") }
        if dto.remark != nil { matched.append("remark") }
        if !dto.tags.isEmpty { matched.append("tags") }
        if dto.categoryName != nil { matched.append("category") }

        return FlexibleTransactionEvidence(
            id: dto.id.uuidString,
            date: df.string(from: dto.date),
            amount: dto.amount,
            type: dto.type,
            note: dto.note,
            remark: dto.remark,
            tags: dto.tags,
            primaryCategory: dto.parentCategoryName,
            subCategory: dto.categoryName,
            matchedFields: matched,
            matchReason: "关键词/分类匹配"
        )
    }

    // MARK: - Summary

    private static func buildSummary(evidences: [FlexibleTransactionDTO]) -> FlexibleQuerySummary {
        let totalMatched = evidences.count
        let totalAmount: Decimal? = totalMatched > 0 ? evidences.reduce(Decimal(0)) { $0 + $1.amount } : nil

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"

        let dateRange: String?
        if let first = evidences.min(by: { $0.date < $1.date }),
           let last = evidences.max(by: { $0.date > $1.date }) {
            dateRange = "\(df.string(from: first.date)) ~ \(df.string(from: last.date))"
        } else {
            dateRange = nil
        }

        // 最频繁的一级分类
        let catCounts = Dictionary(grouping: evidences) { $0.parentCategoryName ?? "未分类" }
            .mapValues { $0.count }
        let topCategory = catCounts.max(by: { $0.value < $1.value })?.key

        return FlexibleQuerySummary(
            totalMatched: totalMatched,
            totalAmount: totalAmount,
            dateRange: dateRange,
            topCategory: topCategory
        )
    }

    // MARK: - Calculation

    private static func calculate(
        plan: FlexibleQueryPlan,
        evidences: [FlexibleTransactionDTO]
    ) -> FlexibleCalculationResult? {
        guard let calc = plan.calculation, calc != .none else { return nil }

        switch calc {
        case .elapsedTimeSinceTransaction:
            guard let latest = evidences.max(by: { $0.date > $1.date }) else { return nil }
            let days = Calendar.current.dateComponents([.day], from: latest.date.startOfDay, to: Date().startOfDay).day ?? 0
            return FlexibleCalculationResult(
                type: .elapsedTimeSinceTransaction,
                valueText: "距今约 \(days) 天",
                days: days,
                amount: nil,
                count: nil,
                date: nil
            )

        case .averageAmount:
            guard !evidences.isEmpty else { return nil }
            let total = evidences.reduce(Decimal(0)) { $0 + $1.amount }
            let avg = total / Decimal(evidences.count)
            return FlexibleCalculationResult(
                type: .averageAmount,
                valueText: "平均 \(Self.formatAmount(avg))",
                days: nil,
                amount: avg,
                count: nil,
                date: nil
            )

        case .daysBetweenTransactions:
            guard evidences.count >= 2 else { return nil }
            let sorted = evidences.sorted { $0.date < $1.date }
            let first = sorted.first!.date
            let last = sorted.last!.date
            let days = Calendar.current.dateComponents([.day], from: first.startOfDay, to: last.startOfDay).day ?? 0
            return FlexibleCalculationResult(
                type: .daysBetweenTransactions,
                valueText: "间隔 \(days) 天",
                days: days,
                amount: nil,
                count: nil,
                date: nil
            )

        case .none:
            return nil
        }
    }

    // MARK: - Empty Result

    private static func buildEmptyResult(plan: FlexibleQueryPlan) -> FlexibleQueryResult {
        let reason = buildEmptyReason(plan: plan)
        let followUp = buildFollowUp(plan: plan)

        return FlexibleQueryResult(
            plan: plan,
            status: .empty,
            summary: FlexibleQuerySummary(totalMatched: 0, totalAmount: nil, dateRange: nil, topCategory: nil),
            matchedTransactions: [],
            calculationResult: nil,
            emptyReason: reason,
            followUpSuggestion: followUp
        )
    }

    private static func buildEmptyReason(plan: FlexibleQueryPlan) -> String {
        var conditions: [String] = []
        if let type = plan.filters.type {
            conditions.append(type == .expense ? "支出" : "收入")
        }
        if let amount = plan.filters.amountGreaterThan {
            conditions.append("金额 > \(formatAmount(amount))")
        }
        if !plan.filters.keywords.isEmpty {
            conditions.append("包含\"\(plan.filters.keywords.joined(separator: "/"))\"")
        }
        if !plan.filters.categoryNames.isEmpty {
            conditions.append("分类\"\(plan.filters.categoryNames.joined(separator: "/"))\"")
        }
        if conditions.isEmpty {
            return "没有找到符合条件的交易记录。"
        }
        return "没有找到\(conditions.joined(separator: " 且 "))的记录。"
    }

    private static func buildFollowUp(plan: FlexibleQueryPlan) -> FlexibleQueryFollowUp? {
        // 有条件时建议放宽
        if !plan.filters.keywords.isEmpty || plan.filters.amountGreaterThan != nil {
            return FlexibleQueryFollowUp(
                question: "要不要我放宽条件再查一次？",
                relaxedPlan: nil
            )
        }
        return nil
    }

    // MARK: - Formatting

    static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}

// MARK: - FlexibleTransactionDTO (Sendable)

/// 后台 context 内映射的值类型，安全跨线程传递
struct FlexibleTransactionDTO: Sendable {
    let id: UUID
    let amount: Decimal
    let type: String
    let date: Date
    let note: String?
    let remark: String?
    let tags: [String]
    let categoryName: String?
    let parentCategoryName: String?
    let aiCandidate: String?
    let accountId: UUID?
}
