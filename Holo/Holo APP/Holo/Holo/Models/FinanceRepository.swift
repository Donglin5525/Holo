//
//  FinanceRepository.swift
//  Holo
//
//  记账功能数据仓库
//  所有 Core Data 操作均在主线程 viewContext 执行，避免跨线程访问导致 EXC_BAD_ACCESS
//

import Foundation
import CoreData
import BackgroundTasks

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
        try validateTransactionCategory(category)

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
        if let cat = updates.category {
            try validateTransactionCategory(cat)
            transaction.category = cat
        }
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

    /// 按查询结果快照取回精确交易集合，并保持快照中的稳定顺序。
    func findTransactions(by ids: [UUID]) -> [Transaction] {
        guard !ids.isEmpty else { return [] }

        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        guard let transactions = try? context.fetch(request) else { return [] }

        var byID: [UUID: Transaction] = [:]
        for transaction in transactions {
            byID[transaction.id] = transaction
        }
        return ids.compactMap { byID[$0] }
    }

    /// 根据 ID 查找分类
    func findCategory(by id: UUID) -> Category? {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// 解析分类层级名称（一级/二级）
    func resolveCategoryNames(from category: Category) -> (primary: String, sub: String?) {
        if let parentId = category.parentId,
           let parent = findCategory(by: parentId) {
            return (parent.name, category.name)
        }
        return (category.name, nil)
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
        try validateTransactionCategory(category)

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

    private func validateTransactionCategory(_ category: Category) throws {
        guard category.isSubCategory else {
            throw FinanceError.subCategoryRequired
        }
    }

    /// 查询子分类所属的一级分类名称
    func parentCategoryName(for category: Category) -> String? {
        guard let parentId = category.parentId else { return nil }
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", parentId as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first?.name
    }

    /// 标记交易为 AI 创建，并记录原始分类候选词
    func markTransactionAsAICreated(_ transactionId: UUID, candidate: String?) {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", transactionId as CVarArg)
        request.fetchLimit = 1
        guard let transaction = try? context.fetch(request).first else { return }
        transaction.isAICreated = true
        transaction.aiCandidate = candidate
        try? context.save()
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
    case subCategoryRequired

    var errorDescription: String? {
        switch self {
        case .invalidData: return "数据无效"
        case .notFound: return "记录不存在"
        case .categoryInUse: return "该分类正在使用中，无法删除"
        case .saveFailed: return "保存失败"
        case .subCategoryRequired: return "记账必须选择二级分类"
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

// MARK: - 长期成本项目

@objc(SpendingProject)
public class SpendingProject: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var kind: String
    @NSManaged public var amount: NSDecimalNumber
    @NSManaged public var frequency: String?
    @NSManaged public var startDate: Date
    @NSManaged public var endDate: Date?
    @NSManaged public var maxOccurrences: Int32
    @NSManaged public var occurrencesGenerated: Int32
    @NSManaged public var plannedLifespanDays: Int32
    @NSManaged public var nextOccurrenceDate: Date?
    @NSManaged public var isPaused: Bool
    @NSManaged public var autoGenerateTransaction: Bool
    @NSManaged public var usageCount: Int32
    @NSManaged public var usageDayCount: Int32
    @NSManaged public var lastUsedDate: Date?
    @NSManaged public var categoryId: UUID?
    @NSManaged public var accountId: UUID?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    var isRecurring: Bool { kind == SpendingProjectKind.recurring.rawValue }
    var hasRemainingOccurrences: Bool {
        guard maxOccurrences <= 0 || occurrencesGenerated < maxOccurrences else { return false }
        if let endDate, let nextOccurrenceDate { return nextOccurrenceDate <= endDate }
        return true
    }
    var amountDecimal: Decimal { amount as Decimal }

    /// 一次性购买从购买日到今天经过的完整自然日数。
    var ownershipElapsedDays: Int {
        let calendar = Calendar.current
        let purchaseDay = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: Date())
        return max(0, calendar.dateComponents([.day], from: purchaseDay, to: today).day ?? 0)
    }

    var monthlyCommitment: Decimal? {
        guard isRecurring else { return nil }
        switch frequency {
        case SpendingProjectFrequency.yearly.rawValue:
            return amountDecimal / 12
        default:
            return amountDecimal
        }
    }

    var dailyCost: Decimal? {
        guard !isRecurring else { return nil }
        return amountDecimal / Decimal(max(ownershipElapsedDays, 1))
    }

    var perUseCost: Decimal? {
        guard !isRecurring, usageCount > 0 else { return nil }
        return amountDecimal / Decimal(usageCount)
    }
}

enum SpendingProjectKind: String, CaseIterable {
    case recurring
    case oneOff
}

enum SpendingProjectFrequency: String, CaseIterable {
    case monthly
    case yearly

    var title: String {
        switch self {
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }
}

enum SpendingProjectEndMode: String, CaseIterable {
    case forever
    case endDate
    case occurrenceCount

    var title: String {
        switch self {
        case .forever: return "无限期"
        case .endDate: return "指定结束日期"
        case .occurrenceCount: return "总周期数"
        }
    }
}

@MainActor
final class SpendingProjectRepository {
    static let shared = SpendingProjectRepository()

    private let finance = FinanceRepository.shared
    private var context: NSManagedObjectContext { finance.context }

    private init() {}

    func allProjects() -> [SpendingProject] {
        let request = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    @discardableResult
    func create(
        name: String,
        kind: SpendingProjectKind,
        amount: Decimal,
        frequency: SpendingProjectFrequency? = nil,
        startDate: Date,
        endDate: Date? = nil,
        maxOccurrences: Int32 = 0,
        plannedLifespanDays: Int32 = 0,
        category: Category? = nil,
        account: Account? = nil,
        autoGenerateTransaction: Bool = true
    ) throws -> SpendingProject {
        let project = SpendingProject(context: context)
        project.id = UUID()
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.kind = kind.rawValue
        project.amount = NSDecimalNumber(decimal: amount)
        project.frequency = frequency?.rawValue
        project.startDate = startDate
        project.endDate = endDate
        project.maxOccurrences = maxOccurrences
        project.occurrencesGenerated = 0
        project.plannedLifespanDays = plannedLifespanDays
        project.nextOccurrenceDate = kind == .recurring ? startDate : nil
        project.isPaused = false
        project.autoGenerateTransaction = autoGenerateTransaction
        project.usageCount = 0
        project.usageDayCount = 0
        project.categoryId = category?.id
        project.accountId = account?.id
        project.createdAt = Date()
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        return project
    }

    func syncRecurringProjects(now: Date = Date()) throws {
        let calendar = Calendar.current
        for project in allProjects() where project.isRecurring && !project.isPaused && project.autoGenerateTransaction && project.hasRemainingOccurrences {
            guard var nextDate = project.nextOccurrenceDate,
                  let frequency = SpendingProjectFrequency(rawValue: project.frequency ?? "monthly") else { continue }

            // 兼容首次升级：已有自动流水时先以实际流水数校准计数。
            let countRequest = NSFetchRequest<Transaction>(entityName: "Transaction")
            countRequest.predicate = NSPredicate(format: "spendingProjectId == %@", project.id as CVarArg)
            project.occurrencesGenerated = Int32((try? context.count(for: countRequest)) ?? Int(project.occurrencesGenerated))

            while nextDate <= now && project.hasRemainingOccurrences {
                if let endDate = project.endDate, nextDate > endDate { break }
                let request = NSFetchRequest<Transaction>(entityName: "Transaction")
                request.predicate = NSPredicate(format: "spendingProjectId == %@ AND date == %@", project.id as CVarArg, nextDate as NSDate)
                request.fetchLimit = 1
                if (try? context.fetch(request).first) == nil {
                    let transaction = Transaction(context: context)
                    transaction.id = UUID()
                    transaction.amount = project.amount
                    transaction.type = TransactionType.expense.rawValue
                    transaction.date = nextDate
                    transaction.note = project.name
                    transaction.remark = "长期成本·自动生成"
                    transaction.createdAt = Date()
                    transaction.updatedAt = Date()
                    transaction.spendingProjectId = project.id
                    if let categoryId = project.categoryId { transaction.category = finance.findCategory(by: categoryId) }
                    if let accountId = project.accountId { transaction.account = finance.findAccount(by: accountId) }
                    project.occurrencesGenerated += 1
                }
                guard let advanced = calendar.date(byAdding: frequency == .yearly ? .year : .month, value: 1, to: nextDate) else { break }
                nextDate = advanced
            }
            project.nextOccurrenceDate = nextDate
            project.updatedAt = Date()
        }
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    func recordUsage(for project: SpendingProject, date: Date = Date()) throws {
        project.usageCount += 1
        if project.lastUsedDate == nil || !Calendar.current.isDate(project.lastUsedDate!, inSameDayAs: date) {
            project.usageDayCount += 1
        }
        project.lastUsedDate = date
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
    }

    func updatePause(for project: SpendingProject, isPaused: Bool) throws {
        project.isPaused = isPaused
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
    }

    func updateEndCondition(for project: SpendingProject, endDate: Date?, maxOccurrences: Int32) throws {
        project.endDate = endDate
        project.maxOccurrences = maxOccurrences
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
    }

    func updateOneOffProject(_ project: SpendingProject, name: String, amount: Decimal, purchaseDate: Date, category: Category) throws {
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.amount = NSDecimalNumber(decimal: amount)
        project.startDate = purchaseDate
        project.categoryId = category.id
        project.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    func deleteProject(id: NSManagedObjectID) throws {
        guard let project = try? context.existingObject(with: id) as? SpendingProject else { return }
        context.delete(project)
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }
}

// MARK: - 周期性支出后台补账

/// 用 BGAppRefreshTask 在系统允许的后台时机补齐周期流水。
/// iOS 不承诺精确到分钟，因此前台启动和打开长期成本页仍会执行同一套幂等补账。
@MainActor
final class SpendingProjectBackgroundService {
    static let shared = SpendingProjectBackgroundService()

    private let taskIdentifier = "com.holo.app.spendingProjectRefresh"

    private init() {}

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            Task { @MainActor in
                guard let refreshTask = task as? BGAppRefreshTask else { return }
                do {
                    try SpendingProjectRepository.shared.syncRecurringProjects()
                    refreshTask.setTaskCompleted(success: true)
                } catch {
                    refreshTask.setTaskCompleted(success: false)
                }
                self.scheduleNextTask()
            }
        }
    }

    func scheduleNextTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)

        let nextDate = SpendingProjectRepository.shared.allProjects()
            .filter { $0.isRecurring && !$0.isPaused && $0.autoGenerateTransaction && $0.hasRemainingOccurrences }
            .compactMap(\.nextOccurrenceDate)
            .min()

        guard let nextDate else { return }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = max(Date().addingTimeInterval(60), nextDate)
        try? BGTaskScheduler.shared.submit(request)
    }
}
