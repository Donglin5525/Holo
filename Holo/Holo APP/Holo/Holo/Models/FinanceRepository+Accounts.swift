//
//  FinanceRepository+Accounts.swift
//  Holo
//
//  账户相关操作
//

import Foundation
import CoreData

extension FinanceRepository {

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

    /// 根据 ID 查找账户，供长期成本自动生成流水使用
    func findAccount(by id: UUID) -> Account? {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
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
        notes: String? = nil,
        billingDay: Int16 = 0,
        dueDay: Int16 = 0,
        creditLimit: Decimal = 0
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
            notes: notes,
            billingDay: billingDay,
            dueDay: dueDay,
            creditLimit: NSDecimalNumber(decimal: creditLimit)
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
        notes: String? = nil,
        type: AccountType? = nil,
        billingDay: Int16? = nil,
        dueDay: Int16? = nil,
        creditLimit: Decimal? = nil
    ) {
        if let name = name { account.name = name }
        if let icon = icon { account.customIcon = icon }
        if let color = color { account.color = color }
        if let notes = notes { account.notes = notes }
        if let type = type { account.type = type.rawValue }
        if let billingDay = billingDay { account.billingDay = billingDay }
        if let dueDay = dueDay { account.dueDay = dueDay }
        if let creditLimit = creditLimit { account.creditLimit = NSDecimalNumber(decimal: creditLimit) }
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

    /// 获取账户当前余额（实时计算：initialBalance + 收入 - 支出 ± 转账）
    /// 转账：本账户作为转出方（account == 本账户）扣减；作为转入方（toAccountId == 本账户.id）增加。
    func getAccountBalance(_ account: Account) -> Decimal {
        // 查询分两步，避免单个复杂 predicate 在 schema 迁移期间崩溃：
        // 1) account == 本账户 的交易（含转出转账）
        // 2) toAccountId == 本账户.id 的交易（转入转账）
        // 两步都用 try? 容错，任一失败不影响另一边。
        var balance = account.initialBalance.decimalValue

        // 1) 账户作为 account（转出方/普通收支）
        let ownRequest = Transaction.fetchRequest()
        ownRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "account == %@", account),
            FinanceTransactionOccurrencePolicy.occurredPredicate()
        ])
        for tx in (try? context.fetch(ownRequest)) ?? [] {
            switch tx.transactionType {
            case .income:
                balance += tx.amount.decimalValue
            case .expense:
                balance -= tx.amount.decimalValue
            case .transfer:
                // 转出方扣减
                balance -= tx.amount.decimalValue
            }
        }

        // 2) 账户作为 toAccountId（转入方）
        let incomingRequest = Transaction.fetchRequest()
        incomingRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "toAccountId == %@", account.id as CVarArg),
            FinanceTransactionOccurrencePolicy.occurredPredicate()
        ])
        for tx in (try? context.fetch(incomingRequest)) ?? [] {
            switch tx.transactionType {
            case .income, .expense:
                break // 普通收支不走 toAccountId
            case .transfer:
                // 转入方增加
                balance += tx.amount.decimalValue
            }
        }

        return balance
    }

    /// 获取截止到指定日期的累计余额（initialBalance + 该日期之前的全部收入-支出）
    /// 转账一进一出净值不变，但单笔方向仍需正确处理。
    func getCumulativeBalance(before date: Date) -> Decimal {
        let accounts = getAccounts(includeArchived: false)

        // 所有账户的初始余额之和
        var balance = accounts.reduce(Decimal(0)) { $0 + $1.initialBalance.decimalValue }

        // 截止日期之前的所有交易
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date < %@", date as NSDate),
            FinanceTransactionOccurrencePolicy.occurredPredicate(asOf: min(date, Date()))
        ])

        guard let transactions = try? context.fetch(request) else {
            return balance
        }

        for tx in transactions {
            switch tx.transactionType {
            case .income:
                balance += tx.amount.decimalValue
            case .expense:
                balance -= tx.amount.decimalValue
            case .transfer:
                // 转账不影响总净值（一进一出相抵），跳过
                break
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

        let isIncome = difference > 0
        let absoluteAmount = abs(difference)
        let transactionType: TransactionType = isIncome ? .income : .expense
        let adjustCategory = try ensureBalanceAdjustmentCategory(type: transactionType)

        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.amount = NSDecimalNumber(decimal: absoluteAmount)
        transaction.type = transactionType.rawValue
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

    private func ensureBalanceAdjustmentCategory(type: TransactionType) throws -> Category {
        let categoryRequest = Category.fetchRequest()
        categoryRequest.predicate = NSPredicate(
            format: "isSystem == true AND name == %@ AND type == %@ AND parentId != nil",
            "余额调整",
            type.rawValue
        )
        categoryRequest.fetchLimit = 1
        if let existing = try context.fetch(categoryRequest).first {
            return existing
        }

        let parentName = type == .income ? "其他收入" : "其他"
        let parentRequest = Category.fetchRequest()
        parentRequest.predicate = NSPredicate(
            format: "name == %@ AND type == %@ AND parentId == nil",
            parentName,
            type.rawValue
        )
        parentRequest.fetchLimit = 1
        guard let parent = try context.fetch(parentRequest).first else {
            throw AccountError.systemCategoryNotFound
        }

        let category = Category.create(
            in: context,
            name: "余额调整",
            icon: "arrow.triangle.2.circlepath",
            color: "#94A3B8",
            type: type.rawValue,
            isDefault: true,
            sortOrder: 999,
            parentId: parent.id,
            isSystem: true
        )
        try context.save()
        return category
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
            switch tx.transactionType {
            case .income:
                income += tx.amount.decimalValue
            case .expense:
                expense += tx.amount.decimalValue
            case .transfer:
                // 转账不计入收支统计，避免虚增收入/支出
                break
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
    func getTransactionCount(for account: Account) -> Int {
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
    
}
