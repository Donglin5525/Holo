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

    /// 模块内测试入口，避免日历等集成测试读写真实数据库。
    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// 延迟初始化：触发 Core Data → seed
    /// 在首次使用 FinanceRepository 时调用
    func setup() {
        _ = context          // 触发 lazy var → CoreDataStack.shared.viewContext
        seedDefaultData()
        migrateLegacyInstallmentNotes()
        migrateFixedExpenseSemantics()
        migrateCardToCreditCard()
    }

    // MARK: - 信用卡类型迁移

    /// 把旧库里 type=="card" 且名字是"信用卡"的种子账户迁移为 creditCard 类型。
    /// 用户自建的 card 账户不动（建的时候大概率当储蓄卡用）。
    private static let creditCardMigrationFlag = "hasMigratedCardToCreditCard_v1"

    private func migrateCardToCreditCard() {
        guard !UserDefaults.standard.bool(forKey: FinanceRepository.creditCardMigrationFlag) else { return }

        let request = Account.fetchRequest()
        request.predicate = NSPredicate(
            format: "type == %@ AND name == %@",
            AccountType.card.rawValue, "信用卡"
        )

        guard let accounts = try? context.fetch(request), !accounts.isEmpty else {
            UserDefaults.standard.set(true, forKey: FinanceRepository.creditCardMigrationFlag)
            return
        }

        for account in accounts {
            account.type = AccountType.creditCard.rawValue
            account.updatedAt = Date()
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: FinanceRepository.creditCardMigrationFlag)
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

    func getAllTransactions(asOf snapshotDate: Date = Date()) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = FinanceTransactionOccurrencePolicy.occurredPredicate(asOf: snapshotDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try context.fetch(request)
    }
    
    func getTransactions(for month: Date) async throws -> [Transaction] {
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return []
        }
        return try await getTransactions(from: monthStart, to: monthEnd)
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
        guard periods >= 2 else { throw FinanceError.invalidData }

        let groupId = UUID()
        let perPeriodBase = totalAmount / Decimal(periods)
        let cleanedNote = InstallmentNoteSanitizer.clean(note)
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

            let tx = Transaction(context: context)
            tx.id = UUID()
            tx.amount = NSDecimalNumber(decimal: periodAmount)
            tx.type = type.rawValue
            tx.category = category
            tx.account = account
            tx.date = periodDate
            tx.note = cleanedNote
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

    /// 原组就地更新，保留交易 ID，避免聊天卡片失联和编辑页持有已删除对象。
    @discardableResult
    func updateInstallmentTransactions(
        groupId: UUID,
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
        guard periods >= 2 else { throw FinanceError.invalidData }

        let existing = try await getInstallmentGroup(groupId: groupId)
        guard !existing.isEmpty else { throw FinanceError.notFound }

        let perPeriodBase = totalAmount / Decimal(periods)
        let cleanedNote = InstallmentNoteSanitizer.clean(note)
        var updated: [Transaction] = []

        for i in 0..<periods {
            guard let periodDate = Calendar.current.date(byAdding: .month, value: i, to: startDate) else {
                continue
            }

            let isLast = i == periods - 1
            let previousSum = perPeriodBase * Decimal(periods - 1)
            let baseAmount = isLast ? (totalAmount - previousSum) : perPeriodBase
            let transaction: Transaction
            if i < existing.count {
                transaction = existing[i]
            } else {
                transaction = Transaction(context: context)
                transaction.id = UUID()
                transaction.createdAt = Date()
            }

            transaction.amount = NSDecimalNumber(decimal: baseAmount + feePerPeriod)
            transaction.type = type.rawValue
            transaction.category = category
            transaction.account = account
            transaction.date = periodDate
            transaction.note = cleanedNote
            transaction.remark = remark
            transaction.updatedAt = Date()
            transaction.installmentGroupId = groupId
            transaction.installmentIndex = Int16(i + 1)
            transaction.installmentTotal = Int16(periods)
            updated.append(transaction)
        }

        if existing.count > periods {
            for transaction in existing.dropFirst(periods) {
                context.delete(transaction)
            }
        }

        try context.save()
        return updated
    }

    /// 清理旧版本已写入商品名称的分期前缀；幂等执行，不改动正常名称。
    private func migrateLegacyInstallmentNotes() {
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "installmentGroupId != nil AND note != nil")
        guard let transactions = try? context.fetch(request) else { return }

        var changed = false
        for transaction in transactions {
            let cleaned = InstallmentNoteSanitizer.clean(transaction.note)
            if cleaned != transaction.note {
                transaction.note = cleaned
                transaction.updatedAt = Date()
                changed = true
            }
        }
        if changed {
            try? context.save()
        }
    }

    /// 统一旧数据到当前产品口径：周期项目按每期金额入账；一次性购买只保留持有成本卡。
    /// 只删除带 spendingProjectId 的系统关联流水，用户手工记账不会受影响。
    @discardableResult
    func migrateFixedExpenseSemantics() -> Int {
        let projectRequest = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
        guard let projects = try? context.fetch(projectRequest), !projects.isEmpty else { return 0 }

        let recurringProjects = projects.filter(\.isRecurring)
        let oneOffProjects = projects.filter { !$0.isRecurring }
        let now = Date()
        var changedCount = 0

        for project in recurringProjects {
            let storedMode = SpendingProjectAmountMode(rawValue: project.amountMode ?? "")
            if storedMode == .projectTotal,
               let perOccurrence = SpendingProjectAmountPolicy.occurrenceAmount(
                   enteredAmount: project.amountDecimal,
                   mode: .projectTotal,
                   totalOccurrences: Int(project.maxOccurrences),
                   occurrenceIndex: 0
               ) {
                project.amount = NSDecimalNumber(decimal: perOccurrence)
                changedCount += 1
            }
            if storedMode != .perOccurrence {
                project.amountMode = SpendingProjectAmountMode.perOccurrence.rawValue
                changedCount += 1
            }
        }

        let recurringIDs = recurringProjects.map(\.id)
        if !recurringIDs.isEmpty {
            let request = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "spendingProjectId IN %@", recurringIDs)
            for transaction in (try? context.fetch(request)) ?? [] {
                var changed = false
                if transaction.projectPostingState != FinanceTransactionProjectPostingState.confirmed.rawValue {
                    transaction.projectPostingState = FinanceTransactionProjectPostingState.confirmed.rawValue
                    changed = true
                }
                if transaction.remark != FinanceTransactionOccurrencePolicy.recurringRemark {
                    transaction.remark = FinanceTransactionOccurrencePolicy.recurringRemark
                    changed = true
                }
                if changed {
                    transaction.updatedAt = now
                    changedCount += 1
                }
            }
        }

        for project in oneOffProjects {
            if project.autoGenerateTransaction || project.occurrencesGenerated != 0 ||
                project.nextOccurrenceDate != nil || project.accountId != nil ||
                project.amountMode != nil || project.paymentMode != nil {
                project.autoGenerateTransaction = false
                project.occurrencesGenerated = 0
                project.nextOccurrenceDate = nil
                project.accountId = nil
                project.amountMode = nil
                project.paymentMode = nil
                project.updatedAt = now
                changedCount += 1
            }
        }

        let oneOffIDs = oneOffProjects.map(\.id)
        if !oneOffIDs.isEmpty {
            let request = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "spendingProjectId IN %@", oneOffIDs)
            for transaction in (try? context.fetch(request)) ?? [] {
                context.delete(transaction)
                changedCount += 1
            }
        }

        guard changedCount > 0 else { return 0 }
        do {
            try context.save()
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            return changedCount
        } catch {
            context.rollback()
            return 0
        }
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
    @NSManaged public var amountMode: String?
    @NSManaged public var paymentMode: String?
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
    var perOccurrenceAmount: Decimal? { isRecurring ? amountDecimal : nil }

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
        project.amountMode = kind == .recurring ? SpendingProjectAmountMode.perOccurrence.rawValue : nil
        project.paymentMode = nil
        project.frequency = frequency?.rawValue
        project.startDate = startDate
        project.endDate = endDate
        project.maxOccurrences = maxOccurrences
        project.occurrencesGenerated = 0
        project.plannedLifespanDays = plannedLifespanDays
        project.nextOccurrenceDate = kind == .recurring ? startDate : nil
        project.isPaused = false
        project.autoGenerateTransaction = kind == .recurring && autoGenerateTransaction
        project.usageCount = 0
        project.usageDayCount = 0
        project.categoryId = category?.id
        project.accountId = kind == .recurring ? account?.id : nil
        project.createdAt = Date()
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        return project
    }

    func syncRecurringProjects(now: Date = Date()) throws {
        let calendar = Calendar.current
        for project in allProjects() {
            guard project.isRecurring,
                  !project.isPaused,
                  project.autoGenerateTransaction,
                  let frequency = SpendingProjectFrequency(rawValue: project.frequency ?? "monthly") else { continue }

            // —— 1. 清理 startDate 之前的项目脏流水 ——
            // 历史补账 bug 可能在开始日期之前造出非法流水；用户手工记账不会带 spendingProjectId，
            // 因此带项目标记且早于 startDate 的流水一定是脏数据，安全删除。
            let preStartRequest = Transaction.fetchRequest()
            preStartRequest.predicate = NSPredicate(
                format: "spendingProjectId == %@ AND date < %@",
                project.id as CVarArg, project.startDate as NSDate
            )
            for tx in (try? context.fetch(preStartRequest)) ?? [] {
                context.delete(tx)
            }

            // —— 2. 以 startDate 为唯一起点，按周期从早到晚补账 ——
            // 不再依赖可能被污染的 nextOccurrenceDate 作为起点，杜绝"往回找历史账单"。
            let step: Calendar.Component = frequency == .yearly ? .year : .month
            var occurrenceDate = project.startDate
            var generatedThisSync = 0

            while occurrenceDate <= now {
                // 达到 endDate 或达上限则停
                if let endDate = project.endDate, occurrenceDate > endDate { break }
                if project.maxOccurrences > 0, generatedThisSync >= Int(project.maxOccurrences) { break }

                // —— 3. 按"年-月"维度判断该期是否已建过 ——
                // 不再用精确到秒的日期比较（编辑/迁移若改动时分秒会导致重复补账）。
                if !hasOccurrence(projectId: project.id, on: occurrenceDate, calendar: calendar) {
                    let transaction = Transaction(context: context)
                    transaction.id = UUID()
                    transaction.amount = project.amount
                    transaction.type = TransactionType.expense.rawValue
                    transaction.date = occurrenceDate
                    transaction.note = project.name
                    transaction.remark = FinanceTransactionOccurrencePolicy.recurringRemark
                    transaction.createdAt = Date()
                    transaction.updatedAt = Date()
                    transaction.spendingProjectId = project.id
                    transaction.projectPostingState = FinanceTransactionProjectPostingState.confirmed.rawValue
                    if let categoryId = project.categoryId { transaction.category = finance.findCategory(by: categoryId) }
                    if let accountId = project.accountId { transaction.account = finance.findAccount(by: accountId) }
                }
                generatedThisSync += 1

                guard let advanced = calendar.date(byAdding: step, value: 1, to: occurrenceDate) else { break }
                occurrenceDate = advanced
            }

            // —— 4. 进度只数"已发生"的流水（date <= now），与余额/统计口径一致 ——
            let occurredCountRequest = Transaction.fetchRequest()
            occurredCountRequest.predicate = NSPredicate(
                format: "spendingProjectId == %@ AND date <= %@",
                project.id as CVarArg, now as NSDate
            )
            project.occurrencesGenerated = Int32((try? context.count(for: occurredCountRequest)) ?? 0)

            // nextOccurrenceDate 推进到下一未到期
            project.nextOccurrenceDate = occurrenceDate
            project.updatedAt = Date()
        }
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    /// 判断某项目在指定日期所属周期（年-月 或 年）是否已存在流水。
    /// 用"年-月"维度去重，避免精确到秒的日期比较在编辑/迁移后失效。
    private func hasOccurrence(projectId: UUID, on date: Date, calendar: Calendar) -> Bool {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let rangeStart = calendar.date(from: comps),
              let rangeEnd = calendar.date(byAdding: .month, value: 1, to: rangeStart) else { return false }
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "spendingProjectId == %@ AND date >= %@ AND date < %@",
            projectId as CVarArg, rangeStart as NSDate, rangeEnd as NSDate
        )
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// 兼容旧调用：一次性购买不补账，只清理旧版本遗留的关联流水。
    func syncOneOffProjects() throws {
        finance.migrateFixedExpenseSemantics()
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

    /// 周期项目只编辑每期金额；已发生流水保持为历史事实，新金额从下次到期生效。
    func updateRecurringProject(_ project: SpendingProject, amount: Decimal, endDate: Date?, maxOccurrences: Int32) throws {
        guard project.isRecurring, amount > 0 else { throw FinanceError.invalidData }
        project.amount = NSDecimalNumber(decimal: amount)
        project.amountMode = SpendingProjectAmountMode.perOccurrence.rawValue
        project.endDate = endDate
        project.maxOccurrences = maxOccurrences
        project.updatedAt = Date()
        try context.save()
        SpendingProjectBackgroundService.shared.scheduleNextTask()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    func updateOneOffProject(_ project: SpendingProject, name: String, amount: Decimal, purchaseDate: Date, category: Category) throws {
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.amount = NSDecimalNumber(decimal: amount)
        project.startDate = purchaseDate
        project.categoryId = category.id
        project.accountId = nil
        project.autoGenerateTransaction = false
        project.occurrencesGenerated = 0
        project.nextOccurrenceDate = nil
        project.amountMode = nil
        project.paymentMode = nil
        project.updatedAt = Date()

        // 兼容历史版本：编辑时顺手清理曾经自动生成的关联流水。
        let request = NSFetchRequest<Transaction>(entityName: "Transaction")
        request.predicate = NSPredicate(format: "spendingProjectId == %@", project.id as CVarArg)
        for transaction in try context.fetch(request) {
            context.delete(transaction)
        }

        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    func deleteProject(id: NSManagedObjectID) throws {
        guard let project = try? context.existingObject(with: id) as? SpendingProject else { return }
        // 历史版本可能残留一次性购买关联流水；删除项目时一并兜底清理。
        if !project.isRecurring {
            let request = NSFetchRequest<Transaction>(entityName: "Transaction")
            request.predicate = NSPredicate(format: "spendingProjectId == %@", project.id as CVarArg)
            for transaction in (try? context.fetch(request)) ?? [] {
                context.delete(transaction)
            }
        }
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
