//
//  CategoryMatcherService.swift
//  Holo
//
//  分类智能匹配服务
//  用于导入账单时智能匹配分类，支持精确匹配、同义词匹配、模糊匹配
//

import Foundation
import CoreData

// MARK: - CategoryMatcherService

/// 分类智能匹配服务（单例）
@MainActor
class CategoryMatcherService {

    static let shared = CategoryMatcherService()
    private init() {}

    // MARK: - 匹配阈值

    /// 模糊匹配的最低相似度阈值（低于此值视为不匹配）
    private let fuzzyMatchThreshold: Double = 0.6

    // MARK: - 公开方法

    /**
     批量匹配分类

     - Parameters:
       - items: 待导入的交易条目
       - categories: 系统已有的分类列表
     - Returns: 匹配结果数组（与 items 顺序一致）
    */
    func batchMatchCategories(
        items: [ImportTransactionItem],
        categories: [Category]
    ) -> [CategoryMatchResult] {
        // 按类型分组分类
        let expenseCategories = categories.filter { $0.type == TransactionType.expense.rawValue }
        let incomeCategories = categories.filter { $0.type == TransactionType.income.rawValue }

        return items.map { item in
            let relevantCategories = item.type == .expense ? expenseCategories : incomeCategories
            return matchSingle(
                primaryCategory: item.primaryCategory,
                subCategory: item.subCategory,
                type: item.type,
                categories: relevantCategories
            )
        }
    }

    /**
     匹配单条分类

     匹配策略（按优先级）：
     1. 精确匹配：名称完全相同（忽略大小写/空白）
     2. 同义词匹配：查同义词映射表
     3. 模糊匹配：Levenshtein 编辑距离 + 公共前缀加成

     - Parameters:
       - primaryCategory: 原始一级分类名
       - subCategory: 原始二级分类名
       - type: 交易类型（支出/收入）
       - categories: 该类型的所有分类
     - Returns: 匹配结果
    */
    func matchSingle(
        primaryCategory: String,
        subCategory: String,
        type: TransactionType,
        categories: [Category]
    ) -> CategoryMatchResult {
        let normalizedPrimary = primaryCategory.trimmingCharacters(in: .whitespaces)
        let normalizedSub = subCategory.trimmingCharacters(in: .whitespaces)

        // 只匹配二级分类（有 parentId 的）
        let subCategories = categories.filter { $0.isSubCategory }

        // ━━━━━━━━━━ 策略 1: 精确匹配 ━━━━━━━━━━
        if let exact = findExactMatch(subCategory: normalizedSub, categories: subCategories) {
            return CategoryMatchResult(
                originalPrimary: normalizedPrimary,
                originalSub: normalizedSub,
                matchType: .exact,
                matchedCategory: exact,
                candidates: [],
                confidence: 1.0,
                isManuallyModified: false
            )
        }

        // ━━━━━━━━━━ 策略 2: 同义词匹配 ━━━━━━━━━━
        if let standardName = CategorySynonymMapping.findStandardSubCategoryName(normalizedSub, type: type),
           let synonymMatch = findExactMatch(subCategory: standardName, categories: subCategories) {
            return CategoryMatchResult(
                originalPrimary: normalizedPrimary,
                originalSub: normalizedSub,
                matchType: .synonym,
                matchedCategory: synonymMatch,
                candidates: [],
                confidence: 0.95,
                isManuallyModified: false
            )
        }

        // ━━━━━━━━━━ 策略 3: 模糊匹配 ━━━━━━━━━━
        let fuzzyResult = findFuzzyMatch(subCategory: normalizedSub, categories: subCategories)
        if let bestMatch = fuzzyResult.bestMatch, fuzzyResult.confidence >= fuzzyMatchThreshold {
            return CategoryMatchResult(
                originalPrimary: normalizedPrimary,
                originalSub: normalizedSub,
                matchType: .fuzzy,
                matchedCategory: bestMatch,
                candidates: fuzzyResult.candidates,
                confidence: fuzzyResult.confidence,
                isManuallyModified: false
            )
        }

        // ━━━━━━━━━━ 无匹配 ━━━━━━━━━━
        return CategoryMatchResult(
            originalPrimary: normalizedPrimary,
            originalSub: normalizedSub,
            matchType: .unmatched,
            matchedCategory: nil,
            candidates: fuzzyResult.candidates,
            confidence: 0,
            isManuallyModified: false
        )
    }

    // MARK: - 私有方法

    /// 精确匹配（忽略大小写和首尾空白）
    private func findExactMatch(subCategory: String, categories: [Category]) -> Category? {
        let normalized = subCategory.lowercased().trimmingCharacters(in: .whitespaces)
        return categories.first { $0.name.lowercased().trimmingCharacters(in: .whitespaces) == normalized }
    }

    /// 模糊匹配（Levenshtein 编辑距离 + 公共前缀加成）
    private func findFuzzyMatch(subCategory: String, categories: [Category]) -> (bestMatch: Category?, candidates: [Category], confidence: Double) {
        let normalized = subCategory.lowercased().trimmingCharacters(in: .whitespaces)

        // 计算所有分类的相似度
        var scoredCategories: [(category: Category, score: Double)] = []

        for category in categories {
            let catName = category.name.lowercased().trimmingCharacters(in: .whitespaces)
            let score = calculateSimilarity(between: normalized, and: catName)
            scoredCategories.append((category, score))
        }

        // 按分数降序排序
        scoredCategories.sort { $0.score > $1.score }

        // 取前 5 个作为候选
        let topCandidates = scoredCategories.prefix(5).map { $0.category }
        let bestScore = scoredCategories.first?.score ?? 0

        return (
            bestMatch: scoredCategories.first?.category,
            candidates: Array(topCandidates),
            confidence: bestScore
        )
    }

    /// 计算两个字符串的相似度（0.0 ~ 1.0）
    /// 综合考虑：编辑距离 + 公共前缀 + 长度差异
    private func calculateSimilarity(between s1: String, and s2: String) -> Double {
        guard !s1.isEmpty && !s2.isEmpty else { return 0 }

        // 编辑距离
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        let editSimilarity = 1.0 - Double(distance) / Double(maxLen)

        // 公共前缀加成
        let commonPrefix = commonPrefixLength(s1, s2)
        let prefixBonus = Double(commonPrefix) / Double(maxLen) * 0.2

        // 包含关系加成（一个字符串包含另一个）
        var containmentBonus = 0.0
        if s1.contains(s2) || s2.contains(s1) {
            containmentBonus = 0.15
        }

        return min(1.0, editSimilarity + prefixBonus + containmentBonus)
    }

    /// Levenshtein 编辑距离
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)

        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)

        // 初始化
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }

        // 填充矩阵
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // 删除
                    matrix[i][j - 1] + 1,      // 插入
                    matrix[i - 1][j - 1] + cost // 替换
                )
            }
        }

        return matrix[a.count][b.count]
    }

    /// 公共前缀长度
    private func commonPrefixLength(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var count = 0

        for i in 0..<min(a.count, b.count) {
            if a[i] == b[i] {
                count += 1
            } else {
                break
            }
        }

        return count
    }

    // MARK: - 统计方法

    /// 生成匹配统计信息
    func generateMatchStatistics(results: [CategoryMatchResult]) -> (exact: Int, synonym: Int, fuzzy: Int, unmatched: Int) {
        var exact = 0, synonym = 0, fuzzy = 0, unmatched = 0

        for result in results {
            switch result.matchType {
            case .exact: exact += 1
            case .synonym: synonym += 1
            case .fuzzy: fuzzy += 1
            case .unmatched: unmatched += 1
            }
        }

        return (exact, synonym, fuzzy, unmatched)
    }

    /// 去重后的匹配结果（相同 originalPrimary+originalSub 只保留一条）
    func deduplicateResults(_ results: [CategoryMatchResult]) -> [CategoryMatchResult] {
        var seen = Set<String>()
        var unique: [CategoryMatchResult] = []

        for result in results {
            let key = result.uniqueKey
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(result)
            }
        }

        return unique
    }
}
