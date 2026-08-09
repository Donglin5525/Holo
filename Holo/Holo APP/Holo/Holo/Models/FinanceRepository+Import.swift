//
//  FinanceRepository+Import.swift
//  Holo
//
//  批量导入
//

import Foundation
import CoreData
import os.log

private let financeImportLogger = Logger(subsystem: "com.holo.app", category: "FinanceImport")

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
        var saveSucceeded = true
        
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
                            icon: "questionmark.folder.fill",
                            color: "#64748B",
                            type: typeStr,
                            isDefault: false,
                            sortOrder: Int16(parentCategoryCache.count),
                            parentId: nil
                        )
                        parentCategoryCache[parentKey] = parentCategory
                        newCategoriesCount += 1
                    }
                    
                    let childCategory = Category.create(
                        in: context,
                        name: item.subCategory,
                        icon: "questionmark.circle.fill",
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
            financeImportLogger.error("批量导入最终保存失败: \(error.localizedDescription)")
            saveSucceeded = false
        }

        return BatchImportResult(
            successCount: successCount,
            failedItems: failedItems,
            newCategoriesCount: newCategoriesCount,
            newAccountsCount: newAccountsCount,
            saveSucceeded: saveSucceeded
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
        var saveSucceeded = true

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

                if let matched = matchResult?.matchedCategory, matched.isSubCategory {
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
                            // 导入文件中的科目即用户真实科目，新分类统一使用待编辑默认图标
                            parentCategory = Category.create(
                                in: context,
                                name: item.primaryCategory,
                                icon: "questionmark.folder.fill",
                                color: "#64748B",
                                type: typeStr,
                                isDefault: false,
                                sortOrder: Int16(parentCategoryCache.count),
                                parentId: nil
                            )
                            parentCategoryCache[parentKey] = parentCategory
                            newCategoriesCount += 1
                        }

                        let childCategory = Category.create(
                            in: context,
                            name: item.subCategory,
                            icon: "questionmark.circle.fill",
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
                    let accType = guessAccountType(name: accountName)
                    let newAccount = Account.create(
                        in: context,
                        name: accountName,
                        type: accType.rawValue,
                        isDefault: false,
                        icon: accType.icon,
                        color: accType.defaultColor
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
            financeImportLogger.error("批量导入最终保存失败: \(error.localizedDescription)")
            saveSucceeded = false
        }

        return BatchImportResult(
            successCount: successCount,
            failedItems: failedItems,
            newCategoriesCount: newCategoriesCount,
            newAccountsCount: newAccountsCount,
            saveSucceeded: saveSucceeded
        )
    }

    // MARK: - 流式导入（阶段二，支持几万条）

    /**
     流式导入 CSV：再次流式遍历文件，边解析边写库

     与 batchImportTransactionsWithMatchResults 的区别：
     - 用独立后台 context，不占用主线程 viewContext，不卡 UI
     - 用 StreamingCSVReader 流式读文件，不全量进内存
     - 分批 save（500 条/批），不 refreshAllObjects（那是 viewContext 用的）
     - 导入时写入 importBatchId / importFingerprint / importOriginalUpdatedAt
     - 去重：批次内指纹集合 + 按 batch 查库，O(1) 而非逐条查
     - 进度回调节流（每 50 条或 200ms 更新一次）

     内存峰值 = 一个批次（500 条）的大小，与文件总条数无关。

     - Parameters:
       - url: CSV 文件 URL
       - fieldMapping: 字段映射（来自扫描阶段，可能被用户编辑过）
       - duplicatePolicy: 重复处理策略（默认跳过重复）
       - onProgress: 进度回调 (当前条数, 总条数)，已节流
     - Returns: 批量导入结果（含 batchId 供撤回用）
     */
    func streamImportTransactions(
        url: URL,
        fieldMapping: FieldMapping,
        detectedTemplate: ImportTemplate,
        headers: [String],
        expectedTotalRows: Int,
        duplicatePolicy: ImportDuplicatePolicy,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> BatchImportResult {
        let batchId = UUID()
        let batchSize = 500

        // 在后台 context 执行所有 Core Data 操作
        let bgContext = CoreDataStack.shared.newBackgroundContext()

        return await bgContext.perform {

            var successCount = 0
            var failedItems: [(index: Int, error: String)] = []
            var newCategoriesCount = 0
            var newAccountsCount = 0
            var skippedDuplicateCount = 0
            var saveSucceeded = true

            // 分类缓存（key = "type:parentName:childName"）
            var categoryCache: [String: Category] = [:]
            var parentCategoryCache: [String: Category] = [:]
            var accountCache: [String: Account] = [:]

            // 预加载已有分类和账户
            self.preloadCaches(
                in: bgContext,
                categoryCache: &categoryCache,
                parentCategoryCache: &parentCategoryCache,
                accountCache: &accountCache
            )

            // 去重：本批次内已写入的指纹集合（防止 CSV 内部重复行）
            var batchFingerprints = Set<String>()
            // 本批次累计计数，用于判断是否该 save
            var batchCount = 0
            // 总行数（用于进度），先扫描一次拿总数
            // 注：这里不再预先数行数（会多一次遍历），改用扫描摘要传入的 totalRows
            // 但为保证进度准确，用一个估算或扫描时记录。这里用事后修正。

            // 进度节流状态
            var lastProgressTime = Date()
            var lastProgressCount = 0
            // 直接用扫描阶段传入的总行数，避免导入时再多遍历一次文件
            let totalRows = expectedTotalRows

            var dataRowIndex = 0  // 数据行索引（0-based，不含表头）
            var isFirstLine = true
            var processedCount = 0

            // 解析并写入单条记录的闭包
            func processAndWrite(row: [String]) {
                dataRowIndex += 1
                processedCount += 1

                // 列数对齐
                var aligned = row
                while aligned.count < headers.count { aligned.append("") }
                if aligned.count > headers.count { aligned = Array(aligned.prefix(headers.count)) }

                // 解析这一行
                let item: ImportTransactionItem
                do {
                    item = try DataImportService.shared.parseRowForStream(
                        aligned,
                        mapping: fieldMapping,
                        template: detectedTemplate
                    )
                } catch {
                    failedItems.append((index: dataRowIndex + 1, error: error.localizedDescription))
                    return
                }

                // 去重检测（默认跳过重复）
                // 两层检测：
                // 1. 本批次内已写入的指纹（防止 CSV 内部重复行）——内存 O(1)
                // 2. 库里历史交易是否有同指纹（防止同一文件重复导入）——查 importFingerprint 索引
                if case .skipDuplicates = duplicatePolicy {
                    let fingerprint = DataImportService.makeFingerprint(
                        date: item.date,
                        amount: item.amount,
                        type: item.type,
                        primaryCategory: item.primaryCategory,
                        subCategory: item.subCategory,
                        accountName: item.accountName
                    )
                    if batchFingerprints.contains(fingerprint) {
                        skippedDuplicateCount += 1
                        return
                    }
                    // 查库里是否已有同指纹交易（importFingerprint 已建索引，查询很快）
                    let dupRequest = Transaction.fetchRequest()
                    dupRequest.predicate = NSPredicate(format: "importFingerprint == %@", fingerprint)
                    dupRequest.fetchLimit = 1
                    let exists = (try? bgContext.count(for: dupRequest)) ?? 0
                    if exists > 0 {
                        skippedDuplicateCount += 1
                        return
                    }
                    batchFingerprints.insert(fingerprint)
                }

                // 匹配/创建分类（精确复用缓存，否则新建）
                let category: Category
                let typeStr = item.type.rawValue
                let cacheKey = "\(typeStr):\(item.primaryCategory):\(item.subCategory)"

                if let cached = categoryCache[cacheKey] {
                    category = cached
                } else {
                    let parentKey = "\(typeStr):\(item.primaryCategory)"
                    let parentCategory: Category
                    if let cachedParent = parentCategoryCache[parentKey] {
                        parentCategory = cachedParent
                    } else {
                        parentCategory = Category.create(
                            in: bgContext,
                            name: item.primaryCategory,
                            icon: "questionmark.folder.fill",
                            color: "#64748B",
                            type: typeStr,
                            isDefault: false,
                            sortOrder: Int16(parentCategoryCache.count),
                            parentId: nil
                        )
                        parentCategory.importBatchId = batchId
                        parentCategoryCache[parentKey] = parentCategory
                        newCategoriesCount += 1
                    }

                    let childCategory = Category.create(
                        in: bgContext,
                        name: item.subCategory,
                        icon: "questionmark.circle.fill",
                        color: parentCategory.color,
                        type: typeStr,
                        isDefault: false,
                        sortOrder: 0,
                        parentId: parentCategory.id
                    )
                    childCategory.importBatchId = batchId
                    categoryCache[cacheKey] = childCategory
                    newCategoriesCount += 1
                    category = childCategory
                }

                // 匹配/创建账户
                let accountName = item.accountName.isEmpty ? "现金" : item.accountName
                let account: Account
                if let cached = accountCache[accountName] {
                    account = cached
                } else {
                    let accType = self.guessAccountType(name: accountName)
                    let newAccount = Account.create(
                        in: bgContext,
                        name: accountName,
                        type: accType.rawValue,
                        isDefault: false,
                        icon: accType.icon,
                        color: accType.defaultColor
                    )
                    newAccount.importBatchId = batchId
                    accountCache[accountName] = newAccount
                    newAccountsCount += 1
                    account = newAccount
                }

                // 创建交易记录
                let transaction = Transaction(context: bgContext)
                let now = Date()
                transaction.id = UUID()
                transaction.amount = NSDecimalNumber(decimal: item.amount)
                transaction.type = item.type.rawValue
                transaction.category = category
                transaction.account = account
                transaction.date = item.date
                transaction.note = item.note
                transaction.tags = item.tags
                transaction.createdAt = now
                transaction.updatedAt = now
                // 导入追踪字段
                transaction.importBatchId = batchId
                transaction.importFingerprint = DataImportService.makeFingerprint(
                    date: item.date,
                    amount: item.amount,
                    type: item.type,
                    primaryCategory: item.primaryCategory,
                    subCategory: item.subCategory,
                    accountName: item.accountName
                )
                transaction.importOriginalUpdatedAt = now

                successCount += 1
                batchCount += 1

                // 分批保存
                if batchCount >= batchSize {
                    do {
                        try bgContext.save()
                        bgContext.reset()
                        batchFingerprints.removeAll()
                        batchCount = 0
                        // reset 后缓存失效，重新加载（只加载已有数据，不含本批新建的）
                        // 重建缓存：保留本批次新建的分类/账户（已 reset，需重新 fetch）
                        self.preloadCaches(
                            in: bgContext,
                            categoryCache: &categoryCache,
                            parentCategoryCache: &parentCategoryCache,
                            accountCache: &accountCache
                        )
                    } catch {
                        financeImportLogger.error("流式导入分批保存失败: \(error.localizedDescription)")
                        failedItems.append((index: dataRowIndex + 1, error: "保存失败：\(error.localizedDescription)"))
                        saveSucceeded = false
                        bgContext.rollback()
                    }
                }

                // 进度节流：每 50 条或 200ms 更新一次
                let progressNow = Date()
                if processedCount % 50 == 0 || progressNow.timeIntervalSince(lastProgressTime) > 0.2 {
                    lastProgressTime = progressNow
                    lastProgressCount = processedCount
                    let current = processedCount
                    let total = totalRows
                    DispatchQueue.main.async {
                        onProgress(current, total)
                    }
                }
            }

            // 流式读取文件并逐行处理
            do {
                try StreamingCSVReader.enumerateLines(in: url) { line in
                    if isFirstLine {
                        isFirstLine = false
                        // 跳过表头（表头已在扫描阶段处理）
                        return
                    }
                    let fields = DataImportService.shared.parseCSVLineForStream(line)
                    processAndWrite(row: fields)
                }
            } catch {
                financeImportLogger.error("流式读取文件失败: \(error.localizedDescription)")
                failedItems.append((index: 0, error: "文件读取失败：\(error.localizedDescription)"))
            }

            // 最终保存剩余数据
            do {
                try bgContext.save()
            } catch {
                financeImportLogger.error("流式导入最终保存失败: \(error.localizedDescription)")
                saveSucceeded = false
            }

            // 最终进度更新
            DispatchQueue.main.async {
                onProgress(processedCount, totalRows)
            }

            return BatchImportResult(
                successCount: successCount,
                failedItems: failedItems,
                newCategoriesCount: newCategoriesCount,
                newAccountsCount: newAccountsCount,
                skippedDuplicateCount: skippedDuplicateCount,
                batchId: batchId,
                saveSucceeded: saveSucceeded
            )
        }
    }

    // MARK: - 撤回导入

    /**
     撤回一次导入批次

     流程：
     1. 查该批次所有交易
     2. 若任一交易被编辑过（updatedAt != importOriginalUpdatedAt）→ 阻止整批撤回
     3. 删除未编辑交易
     4. 删除该批次自动创建（importBatchId == batchId）且无其他交易引用的分类/账户
     5. save + 发 .financeDataDidChange 通知

     - Parameter batchId: 要撤回的批次 ID
     - Returns: 撤回结果（删除的各类对象数量）
     - Throws: UndoBatchError（批次不存在 / 存在已编辑交易）
     */
    func undoImportBatch(batchId: UUID) async throws -> UndoResult {
        let bgContext = CoreDataStack.shared.newBackgroundContext()

        return try await bgContext.perform {

            // 1. 查该批次所有交易
            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(format: "importBatchId == %@", batchId as CVarArg)
            let batchTransactions = (try? bgContext.fetch(txRequest)) ?? []

            guard !batchTransactions.isEmpty else {
                throw UndoBatchError.batchNotFound
            }

            // 2. 冲突检查：有交易在导入后被编辑过
            let editedCount = batchTransactions.filter { tx in
                guard let original = tx.importOriginalUpdatedAt else { return false }
                return tx.updatedAt != original
            }.count
            if editedCount > 0 {
                throw UndoBatchError.editedTransactionsExist(count: editedCount)
            }

            // 3. 删除该批次交易
            for tx in batchTransactions {
                bgContext.delete(tx)
            }
            let deletedTransactions = batchTransactions.count

            // 先保存交易删除，使分类/账户的关系计数反映删除后的真实状态
            try bgContext.save()

            // 4. 删除该批次自动创建且无引用的分类
            //    save 后 transactions 关系已更新，refCount 反映的是"除本批次外还有谁引用"
            var deletedCategories = 0
            let catRequest = Category.fetchRequest()
            catRequest.predicate = NSPredicate(format: "importBatchId == %@", batchId as CVarArg)
            let batchCategories = (try? bgContext.fetch(catRequest)) ?? []
            for cat in batchCategories {
                let refCount = cat.transactions?.count ?? 0
                if refCount == 0 {
                    bgContext.delete(cat)
                    deletedCategories += 1
                }
            }

            // 5. 删除该批次自动创建且无引用的账户
            var deletedAccounts = 0
            let accRequest = Account.fetchRequest()
            accRequest.predicate = NSPredicate(format: "importBatchId == %@", batchId as CVarArg)
            let batchAccounts = (try? bgContext.fetch(accRequest)) ?? []
            for acc in batchAccounts {
                let refCount = acc.transactions?.count ?? 0
                if refCount == 0 {
                    bgContext.delete(acc)
                    deletedAccounts += 1
                }
            }

            // 6. 保存分类/账户删除
            try bgContext.save()

            // 7. 移除批次记录
            ImportBatchRecordService.remove(id: batchId)

            // 8. 发通知刷新 UI（主线程）
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }

            financeImportLogger.info("撤回导入批次 \(batchId)：删除 \(deletedTransactions) 笔交易、\(deletedCategories) 个分类、\(deletedAccounts) 个账户")

            return UndoResult(
                deletedTransactions: deletedTransactions,
                deletedCategories: deletedCategories,
                deletedAccounts: deletedAccounts
            )
        }
    }

    /// 预加载分类和账户缓存（用于流式导入）
    nonisolated private func preloadCaches(
        in context: NSManagedObjectContext,
        categoryCache: inout [String: Category],
        parentCategoryCache: inout [String: Category],
        accountCache: inout [String: Account]
    ) {
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
    nonisolated func guessAccountType(name: String) -> AccountType {
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
