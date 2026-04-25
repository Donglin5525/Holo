//
//  FinanceRepository.swift
//  Holo
//
//  记账功能数据仓库
//  所有 Core Data 操作均在主线程 viewContext 执行，避免跨线程访问导致 EXC_BAD_ACCESS
//

import Foundation
import CoreData

/// 记账功能数据仓库
/// 使用 @MainActor 保证所有操作在主线程执行，返回的对象可在 UI 中安全使用
@MainActor
class FinanceRepository {
    
    // MARK: - Singleton
    
    static let shared = FinanceRepository()
    
    // MARK: - Properties

    /// 主上下文（主线程），UI 相关读写均使用此上下文
    /// 延迟初始化，避免 init 时触发 Core Data
    private lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext

    // MARK: - Initialization

    /// init 不做任何 I/O 操作，避免阻塞主线程
    /// 所有数据操作延迟到 setup() 中执行
    private init() {}

    /// 延迟初始化：触发 Core Data → seed
    /// 在首次使用 FinanceRepository 时调用
    func setup() {
        _ = context          // 触发 lazy var → CoreDataStack.shared.viewContext
        seedDefaultData()
    }
    
    // MARK: - Seed Data
    
    func seedDefaultData() {
        Category.seedDefaultCategories(in: context)
        Account.seedDefaultAccounts(in: context)
        try? context.save()

        // 存量数据迁移：补齐账户 sortOrder、修复默认账户唯一性
        Account.backfillAccounts(in: context)
    }
    
    // MARK: - Transaction Operations
    
    @discardableResult
    func addTransaction(
        amount: Decimal,
        type: TransactionType,
        category: Category,
        account: Account,
        date: Date = Date(),
        note: String? = nil,
        remark: String? = nil,
        tags: [String]? = nil
    ) async throws -> Transaction {
        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.amount = NSDecimalNumber(decimal: amount)
        transaction.type = type.rawValue
        transaction.category = category
        transaction.account = account
        transaction.date = date
        transaction.note = note
        transaction.remark = remark
        transaction.tags = tags
        transaction.createdAt = Date()
        transaction.updatedAt = Date()
        try context.save()
        return transaction
    }
    
    func updateTransaction(_ transaction: Transaction, updates: TransactionUpdates) async throws {
        if let amount = updates.amount { transaction.amount = NSDecimalNumber(decimal: amount) }
        if let cat = updates.category { transaction.category = cat }
        if let acc = updates.account { transaction.account = acc }
        if let date = updates.date { transaction.date = date }
        if let note = updates.note { transaction.note = note }
        if let remark = updates.remark { transaction.remark = remark }
        if let tags = updates.tags { transaction.tags = tags }
        transaction.updatedAt = Date()
        try context.save()
    }
    
    func deleteTransaction(_ transaction: Transaction) async throws {
        context.delete(transaction)
        try context.save()
    }

    /// 根据 ID 查找交易记录
    func findTransaction(by id: UUID) -> Transaction? {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    func getAllTransactions() async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(request)
    }
    
    func getTransactions(for month: Date) async throws -> [Transaction] {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return []
        }
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date < %@", monthStart as NSDate, monthEnd as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(request)
    }
    
    // MARK: - 分期交易操作

    /// 一次性创建分期交易（N 笔）
    @discardableResult
    func addInstallmentTransactions(
        totalAmount: Decimal,
        feePerPeriod: Decimal,
        periods: Int,
        type: TransactionType,
        category: Category,
        account: Account,
        startDate: Date,
        note: String?,
        remark: String? = nil
    ) async throws -> [Transaction] {
        let groupId = UUID()
        let perPeriodBase = totalAmount / Decimal(periods)
        var transactions: [Transaction] = []

        for i in 0..<periods {
            // 末期吸收尾差
            let isLast = (i == periods - 1)
            let previousSum = perPeriodBase * Decimal(periods - 1)
            let baseAmount = isLast ? (totalAmount - previousSum) : perPeriodBase
            let periodAmount = baseAmount + feePerPeriod

            guard let periodDate = Calendar.current.date(byAdding: .month, value: i, to: startDate) else {
                continue
            }

            let notePrefix = "[分期 \(i + 1)/\(periods)]"
            let fullNote = note.map { "\(notePrefix) \($0)" } ?? notePrefix

            let tx = Transaction(context: context)
            tx.id = UUID()
            tx.amount = NSDecimalNumber(decimal: periodAmount)
            tx.type = type.rawValue
            tx.category = category
            tx.account = account
            tx.date = periodDate
            tx.note = fullNote
            tx.remark = remark
            tx.createdAt = Date()
            tx.updatedAt = Date()
            tx.installmentGroupId = groupId
            tx.installmentIndex = Int16(i + 1)
            tx.installmentTotal = Int16(periods)

            transactions.append(tx)
        }

        try context.save()
        return transactions
    }

    /// 查询同一分期组的所有交易
    func getInstallmentGroup(groupId: UUID) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "installmentGroupId == %@", groupId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "installmentIndex", ascending: true)]
        return try context.fetch(request)
    }

    /// 删除整个分期组
    func deleteInstallmentGroup(groupId: UUID) async throws {
        let transactions = try await getInstallmentGroup(groupId: groupId)
        for tx in transactions {
            context.delete(tx)
        }
        try context.save()
    }

    // MARK: - 搜索

    /// 搜索交易记录（按备注和分类名模糊匹配）
    func searchTransactions(keyword: String, limit: Int = 50) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "note CONTAINS[cd] %@ OR category.name CONTAINS[cd] %@",
            keyword, keyword
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = limit
        return try context.fetch(request)
    }

    // MARK: - Category Operations
    
    func getAllCategories() async throws -> [Category] {
        let request = Category.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "type", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]
        return try context.fetch(request)
    }
    
    func getCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@", type.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    /// 获取一级分类（parentId == nil）
    func getTopLevelCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@ AND parentId == nil", type.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    /// 获取指定父分类下的二级子分类
    func getSubCategories(parentId: UUID) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "parentId == %@", parentId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try context.fetch(request)
    }
    
    @discardableResult
    func addCategory(
        name: String,
        icon: String,
        color: String,
        type: TransactionType,
        isDefault: Bool = false,
        parentId: UUID? = nil
    ) async throws -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: icon,
            color: color,
            type: type.rawValue,
            isDefault: isDefault,
            sortOrder: Int16((try? context.count(for: Category.fetchRequest())) ?? 0),
            parentId: parentId
        )
        try context.save()
        return category
    }
    
    /**
     获取最近常用的二级子分类
     
     统计规则：
     1. 查询最近 N 天内的交易记录
     2. 按分类出现频次降序排列
     3. 只返回二级子分类（parentId 非 nil）
     4. 最多返回 limit 个
     
     - Parameters:
       - type: 交易类型（收入/支出）
       - limit: 返回数量上限，默认 8
       - days: 统计的天数窗口，默认 30 天
     - Returns: 按使用频次排序的二级分类数组
     */
    func getRecentCategories(
        type: TransactionType,
        limit: Int = 8,
        days: Int = 30
    ) async throws -> [Category] {
        // 计算时间窗口起点
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        ) ?? Date()
        
        // 查询指定类型、指定时间范围内的所有交易
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND category.type == %@",
            cutoffDate as NSDate,
            type.rawValue
        )
        
        let transactions = try context.fetch(request)
        
        // 统计每个分类的使用次数（仅统计二级子分类）
        var frequencyMap: [NSManagedObjectID: Int] = [:]
        var categoryMap: [NSManagedObjectID: Category] = [:]
        
        for tx in transactions {
            let cat = tx.category
            guard cat.isSubCategory else { continue }
            let oid = cat.objectID
            frequencyMap[oid, default: 0] += 1
            categoryMap[oid] = cat
        }
        
        // 按频次降序取前 limit 个
        let sorted = frequencyMap
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { categoryMap[$0.key] }
        
        return Array(sorted)
    }
    
    func updateCategory(_ category: Category, updates: CategoryUpdates) async throws {
        if let name = updates.name { category.name = name }
        if let icon = updates.icon { category.icon = icon }
        if let color = updates.color { category.color = color }
        if let sortOrder = updates.sortOrder { category.sortOrder = sortOrder }
        try context.save()
    }
    
    func deleteCategory(_ category: Category) async throws {
        // 清理该分类的预算记录
        Budget.deleteForCategory(category.id, in: context)

        // 检查该分类本身是否被交易使用
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "category == %@", category)
        if try context.count(for: request) > 0 {
            throw FinanceError.categoryInUse
        }

        // 检查子分类是否被交易使用，并收集未使用的子分类
        let subRequest = Category.fetchRequest()
        subRequest.predicate = NSPredicate(format: "parentId == %@", category.id as CVarArg)
        let subCategories = try context.fetch(subRequest)

        for sub in subCategories {
            // 清理子分类的预算记录
            Budget.deleteForCategory(sub.id, in: context)

            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(format: "category == %@", sub)
            if try context.count(for: txRequest) > 0 {
                throw FinanceError.categoryInUse
            }
            context.delete(sub)
        }

        context.delete(category)
        try context.save()
    }

    /// 批量清理非预设分类（导入时自动创建的）
    /// - Returns: (已删除数量, 跳过数量-被交易使用)
    func cleanupImportedCategories() async throws -> (deleted: Int, skipped: Int) {
        // 获取所有非预设分类
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "isDefault == NO")
        let nonDefaultCategories = try context.fetch(request)

        var deleted = 0
        var skipped = 0

        for category in nonDefaultCategories {
            // 检查是否被交易使用
            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(format: "category == %@", category)
            let inUse = try context.count(for: txRequest) > 0

            if inUse {
                skipped += 1
            } else {
                context.delete(category)
                deleted += 1
            }
        }

        if deleted > 0 {
            try context.save()
        }

        return (deleted, skipped)
    }

    // MARK: - Account Operations

    func getAllAccounts() async throws -> [Account] {
        let request = Account.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "isDefault", ascending: false),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]
        return try context.fetch(request)
    }

    /// 获取账户列表（可选是否包含归档）
    func getAccounts(includeArchived: Bool = false) -> [Account] {
        let request = Account.fetchRequest()
        if !includeArchived {
            request.predicate = NSPredicate(format: "isArchived == false")
        }
        request.sortDescriptors = [
            NSSortDescriptor(key: "isDefault", ascending: false),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]
        return (try? context.fetch(request)) ?? []
    }

    func getDefaultAccount() async throws -> Account? {
        Account.getDefaultAccount(in: context)
    }

    /// 同步版本获取默认账户
    func getDefaultAccountSync() -> Account? {
        Account.getDefaultAccount(in: context)
    }

    // MARK: 账户 CRUD

    /// 创建新账户
    @discardableResult
    func addAccount(
        name: String,
        type: AccountType,
        icon: String = "",
        color: String? = nil,
        initialBalance: Decimal = 0,
        notes: String? = nil
    ) -> Account {
        let accountColor = color ?? type.defaultColor
        let sortOrder = Int16(getAccounts(includeArchived: true).count)

        let account = Account.create(
            in: context,
            name: name,
            type: type.rawValue,
            initialBalance: NSDecimalNumber(decimal: initialBalance),
            icon: icon,
            color: accountColor,
            sortOrder: sortOrder,
            notes: notes
        )
        try? context.save()
        return account
    }

    /// 更新账户信息
    func updateAccount(
        _ account: Account,
        name: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        notes: String? = nil
    ) {
        if let name = name { account.name = name }
        if let icon = icon { account.customIcon = icon }
        if let color = color { account.color = color }
        if let notes = notes { account.notes = notes }
        account.updatedAt = Date()
        try? context.save()
    }

    /// 删除账户（有交易的账户不可删除）
    func deleteAccount(_ account: Account) throws {
        let transactionCount = getTransactionCount(for: account)
        guard transactionCount == 0 else {
            throw AccountError.hasTransactions(count: transactionCount)
        }
        guard !account.isDefault else {
            throw AccountError.cannotDeleteDefault
        }
        // 清理该账户的所有预算记录
        Budget.deleteAllForAccount(account.id, in: context)
        context.delete(account)
        try context.save()
    }

    /// 归档账户（默认账户不可归档）
    func archiveAccount(_ account: Account) throws {
        guard !account.isDefault else {
            throw AccountError.cannotArchiveDefault
        }
        account.isArchived = true
        account.updatedAt = Date()
        try context.save()
    }

    /// 取消归档
    func unarchiveAccount(_ account: Account) {
        account.isArchived = false
        account.updatedAt = Date()
        try? context.save()
    }

    // MARK: 默认账户管理

    /// 设置默认账户（旧默认取消，新默认设置）
    func setDefaultAccount(_ account: Account) {
        // 取消当前默认
        if let currentDefault = Account.getDefaultAccount(in: context) {
            currentDefault.isDefault = false
        }
        account.isDefault = true
        account.updatedAt = Date()
        try? context.save()
    }

    /// 确保有默认账户（兜底）
    func ensureDefaultAccount() {
        Account.ensureDefaultAccount(in: context)
    }

    // MARK: 余额计算

    /// 获取账户当前余额（实时计算：initialBalance + 收入 - 支出）
    func getAccountBalance(_ account: Account) -> Decimal {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "account == %@", account)

        guard let transactions = try? context.fetch(request) else {
            return account.initialBalance.decimalValue
        }

        var balance = account.initialBalance.decimalValue
        for tx in transactions {
            if tx.transactionType == .income {
                balance += tx.amount.decimalValue
            } else {
                balance -= tx.amount.decimalValue
            }
        }
        return balance
    }

    /// 获取净资产信息（总资产、总负债、净资产）
    func getTotalNetWorth() -> (assets: Decimal, liabilities: Decimal, netWorth: Decimal) {
        let accounts = getAccounts(includeArchived: false)
        var totalAssets: Decimal = 0
        var totalLiabilities: Decimal = 0

        for account in accounts {
            let balance = getAccountBalance(account)
            if balance >= 0 {
                totalAssets += balance
            } else {
                totalLiabilities += abs(balance)
            }
        }

        return (totalAssets, totalLiabilities, totalAssets - totalLiabilities)
    }

    // MARK: 余额调整

    /// 余额调整（创建 income/expense 交易 + "余额调整"分类）
    @discardableResult
    func adjustBalance(
        account: Account,
        newBalance: Decimal,
        note: String?,
        date: Date = Date()
    ) throws -> Transaction {
        let currentBalance = getAccountBalance(account)
        let difference = newBalance - currentBalance

        guard difference != 0 else {
            throw AccountError.noBalanceChange
        }

        // 查找系统分类"余额调整"
        let categoryRequest = Category.fetchRequest()
        categoryRequest.predicate = NSPredicate(format: "isSystem == true AND name == %@", "余额调整")
        categoryRequest.fetchLimit = 1
        guard let adjustCategory = try context.fetch(categoryRequest).first else {
            throw AccountError.systemCategoryNotFound
        }

        let isIncome = difference > 0
        let absoluteAmount = abs(difference)

        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.amount = NSDecimalNumber(decimal: absoluteAmount)
        transaction.type = isIncome ? TransactionType.income.rawValue : TransactionType.expense.rawValue
        transaction.category = adjustCategory
        transaction.account = account
        transaction.date = date
        transaction.note = note ?? "[余额调整]"
        transaction.remark = nil
        transaction.tags = nil
        transaction.createdAt = Date()
        transaction.updatedAt = Date()
        try context.save()
        return transaction
    }

    // MARK: 账户详情查询

    /// 获取账户月度收支统计
    func getAccountMonthlySummary(accountId: UUID, month: Date) -> (income: Decimal, expense: Decimal, net: Decimal) {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!

        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "account.id == %@ AND date >= %@ AND date < %@",
            accountId as CVarArg,
            monthStart as NSDate,
            monthEnd as NSDate
        )

        guard let transactions = try? context.fetch(request) else {
            return (0, 0, 0)
        }

        var income: Decimal = 0
        var expense: Decimal = 0
        for tx in transactions {
            if tx.transactionType == .income {
                income += tx.amount.decimalValue
            } else {
                expense += tx.amount.decimalValue
            }
        }

        return (income, expense, income - expense)
    }

    /// 获取账户的交易列表
    func getAccountTransactions(accountId: UUID, from: Date? = nil, to: Date? = nil) -> [Transaction] {
        let request = Transaction.fetchRequest()
        var predicates = [NSPredicate(format: "account.id == %@", accountId as CVarArg)]

        if let from = from {
            predicates.append(NSPredicate(format: "date >= %@", from as NSDate))
        }
        if let to = to {
            predicates.append(NSPredicate(format: "date < %@", to as NSDate))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// 获取账户最近一笔交易的日期
    func getAccountLastTransactionDate(_ account: Account) -> Date? {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "account == %@", account)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first?.date
    }

    /// 获取账户的交易数量
    private func getTransactionCount(for account: Account) -> Int {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "account == %@", account)
        return (try? context.count(for: request)) ?? 0
    }

    /// 更新账户排序
    func updateAccountSortOrders(_ accounts: [Account]) {
        for (index, account) in accounts.enumerated() {
            account.sortOrder = Int16(index)
        }
        try? context.save()
    }
    
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
    private func guessCategoryIconAndColor(name: String, type: TransactionType) -> (icon: String, color: String) {
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
    private func guessAccountType(name: String) -> AccountType {
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
    private func reloadCaches(
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

// MARK: - Update Models

struct TransactionUpdates {
    var amount: Decimal?
    var category: Category?
    var account: Account?
    var date: Date?
    var note: String?
    var remark: String?
    var tags: [String]?
}

struct CategoryUpdates {
    var name: String?
    var icon: String?
    var color: String?
    var sortOrder: Int16?
}

// MARK: - Finance Errors

enum FinanceError: LocalizedError {
    case invalidData
    case notFound
    case categoryInUse
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "数据无效"
        case .notFound: return "记录不存在"
        case .categoryInUse: return "该分类正在使用中，无法删除"
        case .saveFailed: return "保存失败"
        }
    }
}

// MARK: - Account Errors

enum AccountError: LocalizedError {
    case hasTransactions(count: Int)
    case cannotDeleteDefault
    case cannotArchiveDefault
    case noBalanceChange
    case systemCategoryNotFound

    var errorDescription: String? {
        switch self {
        case .hasTransactions(let count):
            return "该账户有 \(count) 笔交易，无法删除"
        case .cannotDeleteDefault:
            return "请先将其他账户设为默认"
        case .cannotArchiveDefault:
            return "请先将其他账户设为默认"
        case .noBalanceChange:
            return "余额未发生变化"
        case .systemCategoryNotFound:
            return "系统分类「余额调整」未找到"
        }
    }
}

// MARK: - Array 安全下标

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
