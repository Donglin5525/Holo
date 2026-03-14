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
    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }
    
    // MARK: - Initialization
    
    private init() {
        seedDefaultData()
    }
    
    // MARK: - Seed Data
    
    func seedDefaultData() {
        Category.seedDefaultCategories(in: context)
        Account.seedDefaultAccounts(in: context)
        try? context.save()
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
        if let tags = updates.tags { transaction.tags = tags }
        transaction.updatedAt = Date()
        try context.save()
    }
    
    func deleteTransaction(_ transaction: Transaction) async throws {
        context.delete(transaction)
        try context.save()
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
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "category == %@", category)
        if try context.count(for: request) > 0 {
            throw FinanceError.categoryInUse
        }
        context.delete(category)
        try context.save()
    }
    
    // MARK: - Account Operations
    
    func getAllAccounts() async throws -> [Account] {
        let request = Account.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "isDefault", ascending: false)]
        return try context.fetch(request)
    }
    
    func getDefaultAccount() async throws -> Account? {
        Account.getDefaultAccount(in: context)
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
}

// MARK: - Update Models

struct TransactionUpdates {
    var amount: Decimal?
    var category: Category?
    var account: Account?
    var date: Date?
    var note: String?
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
