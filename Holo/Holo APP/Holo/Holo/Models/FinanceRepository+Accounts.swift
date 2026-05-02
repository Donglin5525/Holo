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
