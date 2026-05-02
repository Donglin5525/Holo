//
//  FinanceRepository+Import.swift
//  Holo
//
//  批量导入
//

import Foundation
import CoreData

extension FinanceRepository {

    // MARK: - 批量导入
    
    /**
     批量导入交易记录
     
     处理流程：
     1. 预先缓存所有已有分类和账户（减少查询次数）
     2. 逐条匹配/创建分类和账户
     3. 每 100 条保存一次（控制内存峰值）
     4. 返回导入结果（含成功/失败/新建统计）
     
     - Parameters:
       - items: 待导入的交易条目
       - onProgress: 进度回调 (当前条数, 总条数)
     - Returns: 批量导入结果
     */
    func batchImportTransactions(
        _ items: [ImportTransactionItem],
        onProgress: @escaping (Int, Int) -> Void
    ) async -> BatchImportResult {
        var successCount = 0
        var failedItems: [(index: Int, error: String)] = []
        var newCategoriesCount = 0
        var newAccountsCount = 0
        
        // 缓存已有的分类（key = "type:parentName:childName"）
        var categoryCache: [String: Category] = [:]
        // 缓存一级分类（key = "type:name"）
        var parentCategoryCache: [String: Category] = [:]
        // 缓存已有的账户（key = name）
        var accountCache: [String: Account] = [:]
        
        // 预加载所有分类
        if let allCategories = try? context.fetch(Category.fetchRequest()) {
            for cat in allCategories {
                if cat.isTopLevel {
                    parentCategoryCache["\(cat.type):\(cat.name)"] = cat
                } else if let pid = cat.parentId {
                    // 查找父级名称用于组合 key
                    if let parent = allCategories.first(where: { $0.id == pid }) {
                        categoryCache["\(cat.type):\(parent.name):\(cat.name)"] = cat
                    }
                }
            }
        }
        
        // 预加载所有账户
        if let allAccounts = try? context.fetch(Account.fetchRequest()) {
            for acc in allAccounts {
                accountCache[acc.name] = acc
            }
        }
        
        let batchSize = 100
        
        for (index, item) in items.enumerated() {
            do {
                // --- 匹配或创建分类 ---
                let typeStr = item.type.rawValue
                let cacheKey = "\(typeStr):\(item.primaryCategory):\(item.subCategory)"
                
                let category: Category
                if let cached = categoryCache[cacheKey] {
                    category = cached
                } else {
                    // 查找或创建一级分类
                    let parentKey = "\(typeStr):\(item.primaryCategory)"
                    let parentCategory: Category
                    if let cachedParent = parentCategoryCache[parentKey] {
                        parentCategory = cachedParent
                    } else {
                        // 新建一级分类
                        parentCategory = Category.create(
                            in: context,
                            name: item.primaryCategory,
                            icon: "questionmark.circle",
                            color: "#64748B",
                            type: typeStr,
                            isDefault: false,
                            sortOrder: Int16(parentCategoryCache.count),
                            parentId: nil
                        )
                        parentCategoryCache[parentKey] = parentCategory
                        newCategoriesCount += 1
                    }
                    
                    // 查找或创建二级分类
                    if item.subCategory == item.primaryCategory {
                        // 一级和二级同名时直接使用一级分类
                        category = parentCategory
                    } else {
                        let childCategory = Category.create(
                            in: context,
                            name: item.subCategory,
                            icon: "questionmark.circle",
                            color: parentCategory.color,
                            type: typeStr,
                            isDefault: false,
                            sortOrder: 0,
                            parentId: parentCategory.id
                        )
                        categoryCache[cacheKey] = childCategory
                        newCategoriesCount += 1
                        category = childCategory
                    }
                }
                
                // --- 匹配或创建账户 ---
                let accountName = item.accountName.isEmpty ? "现金" : item.accountName
                let account: Account
                if let cached = accountCache[accountName] {
                    account = cached
                } else {
                    // 新建账户，根据名称推测类型，设置对应图标和颜色
                    let accType = guessAccountType(name: accountName)
                    let newAccount = Account.create(
                        in: context,
                        name: accountName,
                        type: accType.rawValue,
                        isDefault: false,
                        icon: accType.icon,
                        color: accType.defaultColor,
                        sortOrder: Int16(accountCache.count)
                    )
                    accountCache[accountName] = newAccount
                    newAccountsCount += 1
                    account = newAccount
                }
                
                // --- 创建交易记录 ---
                let transaction = Transaction(context: context)
                transaction.id = UUID()
                transaction.amount = NSDecimalNumber(decimal: item.amount)
                transaction.type = item.type.rawValue
                transaction.category = category
                transaction.account = account
                transaction.date = item.date
                transaction.note = item.note
                transaction.tags = item.tags
                transaction.createdAt = Date()
                transaction.updatedAt = Date()
                
                successCount += 1
                
                // 分批保存
                if (index + 1) % batchSize == 0 {
                    try context.save()
                    context.refreshAllObjects()
                    // 重新加载缓存（refreshAllObjects 会清除引用）
                    reloadCaches(
                        categoryCache: &categoryCache,
                        parentCategoryCache: &parentCategoryCache,
                        accountCache: &accountCache
                    )
                }
                
            } catch {
                failedItems.append((index: index + 2, error: error.localizedDescription))
            }
            
            onProgress(index + 1, items.count)
        }
        
        // 保存剩余数据
        do {
            try context.save()
        } catch {
            print("[FinanceRepository] 批量导入最终保存失败: \(error)")
        }
        
        return BatchImportResult(
            successCount: successCount,
            failedItems: failedItems,
            newCategoriesCount: newCategoriesCount,
            newAccountsCount: newAccountsCount
        )
    }

    /**
     批量导入交易记录（使用预匹配结果）

     与 batchImportTransactions 的区别：
     - 使用预先匹配好的分类结果，不再重复匹配
     - 对于无匹配的分类，智能选择图标和颜色

     - Parameters:
       - items: 待导入的交易条目
       - matchResults: 预匹配结果（与 items 顺序一致）
       - onProgress: 进度回调 (当前条数, 总条数)
     - Returns: 批量导入结果
    */
    func batchImportTransactionsWithMatchResults(
        _ items: [ImportTransactionItem],
        matchResults: [CategoryMatchResult],
        onProgress: @escaping (Int, Int) -> Void
    ) async -> BatchImportResult {
        var successCount = 0
        var failedItems: [(index: Int, error: String)] = []
        var newCategoriesCount = 0
        var newAccountsCount = 0

        // 缓存已有的分类（key = "type:parentName:childName"）
        var categoryCache: [String: Category] = [:]
        // 缓存一级分类（key = "type:name"）
        var parentCategoryCache: [String: Category] = [:]
        // 缓存已有的账户（key = name）
        var accountCache: [String: Account] = [:]

        // 预加载所有分类
        if let allCategories = try? context.fetch(Category.fetchRequest()) {
            for cat in allCategories {
                if cat.isTopLevel {
                    parentCategoryCache["\(cat.type):\(cat.name)"] = cat
                } else if let pid = cat.parentId {
                    if let parent = allCategories.first(where: { $0.id == pid }) {
                        categoryCache["\(cat.type):\(parent.name):\(cat.name)"] = cat
                    }
                }
            }
        }

        // 预加载所有账户
        if let allAccounts = try? context.fetch(Account.fetchRequest()) {
            for acc in allAccounts {
                accountCache[acc.name] = acc
            }
        }

        let batchSize = 100

        for (index, item) in items.enumerated() {
            do {
                let typeStr = item.type.rawValue

                // --- 使用匹配结果获取分类 ---
                let matchResult = matchResults[safe: index]
                let category: Category

                if let matched = matchResult?.matchedCategory {
                    // 使用匹配到的分类
                    category = matched
                } else {
                    // 无匹配，需要创建新分类
                    let cacheKey = "\(typeStr):\(item.primaryCategory):\(item.subCategory)"

                    if let cached = categoryCache[cacheKey] {
                        category = cached
                    } else {
                        // 查找或创建一级分类
                        let parentKey = "\(typeStr):\(item.primaryCategory)"
                        let parentCategory: Category
                        if let cachedParent = parentCategoryCache[parentKey] {
                            parentCategory = cachedParent
                        } else {
                            // 新建一级分类，智能选择图标和颜色
                            let (icon, color) = guessCategoryIconAndColor(name: item.primaryCategory, type: item.type)
                            parentCategory = Category.create(
                                in: context,
                                name: item.primaryCategory,
                                icon: icon,
                                color: color,
                                type: typeStr,
                                isDefault: false,
                                sortOrder: Int16(parentCategoryCache.count),
                                parentId: nil
                            )
                            parentCategoryCache[parentKey] = parentCategory
                            newCategoriesCount += 1
                        }

                        // 查找或创建二级分类
                        if item.subCategory == item.primaryCategory {
                            category = parentCategory
                        } else {
                            let (childIcon, _) = guessCategoryIconAndColor(name: item.subCategory, type: item.type)
                            let childCategory = Category.create(
                                in: context,
                                name: item.subCategory,
                                icon: childIcon,
                                color: parentCategory.color,
                                type: typeStr,
                                isDefault: false,
                                sortOrder: 0,
                                parentId: parentCategory.id
                            )
                            categoryCache[cacheKey] = childCategory
                            newCategoriesCount += 1
                            category = childCategory
                        }
                    }
                }

                // --- 匹配或创建账户 ---
                let accountName = item.accountName.isEmpty ? "现金" : item.accountName
                let account: Account
                if let cached = accountCache[accountName] {
                    account = cached
                } else {
                    let accType = guessAccountType(name: accountName)
                    let newAccount = Account.create(
                        in: context,
                        name: accountName,
                        type: accType.rawValue,
                        isDefault: false
                    )
                    accountCache[accountName] = newAccount
                    newAccountsCount += 1
                    account = newAccount
                }

                // --- 创建交易记录 ---
                let transaction = Transaction(context: context)
                transaction.id = UUID()
                transaction.amount = NSDecimalNumber(decimal: item.amount)
                transaction.type = item.type.rawValue
                transaction.category = category
                transaction.account = account
                transaction.date = item.date
                transaction.note = item.note
                transaction.tags = item.tags
                transaction.createdAt = Date()
                transaction.updatedAt = Date()

                successCount += 1

                // 分批保存
                if (index + 1) % batchSize == 0 {
                    try context.save()
                    context.refreshAllObjects()
                    reloadCaches(
                        categoryCache: &categoryCache,
                        parentCategoryCache: &parentCategoryCache,
                        accountCache: &accountCache
                    )
                }

            } catch {
                failedItems.append((index: index + 2, error: error.localizedDescription))
            }

            onProgress(index + 1, items.count)
        }

        // 保存剩余数据
        do {
            try context.save()
        } catch {
            // 保存失败
        }

        return BatchImportResult(
            successCount: successCount,
            failedItems: failedItems,
            newCategoriesCount: newCategoriesCount,
            newAccountsCount: newAccountsCount
        )
    }

    /// 根据分类名称智能推测图标和颜色
    func guessCategoryIconAndColor(name: String, type: TransactionType) -> (icon: String, color: String) {
        let n = name.lowercased()

        // 支出分类颜色映射
        let expenseMapping: [(keywords: [String], icon: String, color: String)] = [
            (["餐", "饭", "食", "吃", "饮", "咖啡", "外卖", "早餐", "午餐", "晚餐"], "fork.knife", "#13A4EC"),
            (["交通", "打车", "地铁", "公交", "出租", "滴滴", "单车", "加油", "停车"], "car.fill", "#10B981"),
            (["购物", "买", "服饰", "数码", "日用", "美妆", "家具"], "bag.fill", "#F97316"),
            (["娱乐", "电影", "游戏", "音乐", "ktv", "旅游"], "music.note.list", "#EC4899"),
            (["居住", "房租", "水费", "电费", "燃气", "物业", "网费"], "house.fill", "#6366F1"),
            (["医疗", "药", "看病", "体检", "健康"], "stethoscope", "#F43F5E"),
            (["学习", "课程", "教材", "考试", "培训", "教育"], "book.closed.fill", "#06B6D4"),
            (["社交", "宠物", "理发", "洗衣", "维修", "保险"], "questionmark.folder.fill", "#64748B"),
        ]

        // 收入分类颜色映射
        let incomeMapping: [(keywords: [String], icon: String, color: String)] = [
            (["投资", "利息", "股票", "理财", "基金"], "chart.line.uptrend.xyaxis", "#3B82F6"),
            (["工资", "奖金", "薪资", "兼职", "薪水"], "banknote.fill", "#22C55E"),
            (["红包", "礼金", "人情", "中奖"], "yensign.circle.fill", "#EF4444"),
            (["退款", "退货", "转入", "还款"], "arrow.counterclockwise.circle.fill", "#A855F7"),
        ]

        let mapping = type == .expense ? expenseMapping : incomeMapping

        for (keywords, icon, color) in mapping {
            for keyword in keywords {
                if n.contains(keyword) {
                    return (icon, color)
                }
            }
        }

        // 默认值
        return (type == .expense ? "questionmark.folder.fill" : "plus.circle.fill", "#64748B")
    }

    // MARK: - 导入辅助方法
    
    /// 根据账户名称推测账户类型
    func guessAccountType(name: String) -> AccountType {
        let n = name.lowercased()
        if n.contains("微信") || n.contains("支付宝") || n.contains("wechat") || n.contains("alipay") {
            return .digital
        }
        if n.contains("信用卡") || n.contains("银行") || n.contains("储蓄") || n.contains("card") || n.contains("bank") {
            return .card
        }
        if n.contains("现金") || n.contains("钱包") || n.contains("cash") {
            return .cash
        }
        return .other
    }
    
    /// 重新加载分类和账户缓存（refreshAllObjects 后需要）
    func reloadCaches(
        categoryCache: inout [String: Category],
        parentCategoryCache: inout [String: Category],
        accountCache: inout [String: Account]
    ) {
        categoryCache.removeAll()
        parentCategoryCache.removeAll()
        accountCache.removeAll()
        
        if let allCategories = try? context.fetch(Category.fetchRequest()) {
            for cat in allCategories {
                if cat.isTopLevel {
                    parentCategoryCache["\(cat.type):\(cat.name)"] = cat
                } else if let pid = cat.parentId {
                    if let parent = allCategories.first(where: { $0.id == pid }) {
                        categoryCache["\(cat.type):\(parent.name):\(cat.name)"] = cat
                    }
                }
            }
        }
        if let allAccounts = try? context.fetch(Account.fetchRequest()) {
            for acc in allAccounts {
                accountCache[acc.name] = acc
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
