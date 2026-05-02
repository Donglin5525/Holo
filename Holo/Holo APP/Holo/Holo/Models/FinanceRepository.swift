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
    lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext

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
