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
    
    @discardableResult
    func addCategory(
        name: String,
        icon: String,
        color: String,
        type: TransactionType,
        isDefault: Bool = false
    ) async throws -> Category {
        let count = (try? context.count(for: Category.fetchRequest())) ?? 0
        let category = Category(context: context)
        category.id = UUID()
        category.name = name
        category.icon = icon
        category.color = color
        category.type = type.rawValue
        category.isDefault = isDefault
        category.sortOrder = Int16(count)
        try context.save()
        return category
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
