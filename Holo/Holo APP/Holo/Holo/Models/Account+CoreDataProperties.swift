//
//  Account+CoreDataProperties.swift
//  Holo
//
//  账户扩展 - 静态方法和预设数据
//

import Foundation
import CoreData

extension Account {

    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Account> {
        return NSFetchRequest<Account>(entityName: "Account")
    }

    // MARK: - Factory Methods

    /// 创建新的账户
    static func create(
        in context: NSManagedObjectContext,
        name: String,
        type: String,
        isDefault: Bool = false,
        initialBalance: NSDecimalNumber = NSDecimalNumber(value: 0),
        icon: String = "",
        color: String = "#64748B",
        sortOrder: Int16 = 0,
        notes: String? = nil
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.name = name
        account.type = type
        account.isDefault = isDefault
        account.initialBalance = initialBalance
        account.customIcon = icon
        account.color = color
        account.sortOrder = sortOrder
        account.isArchived = false
        account.notes = notes
        account.createdAt = Date()
        account.updatedAt = Date()

        return account
    }

    // MARK: - Default Accounts

    /// 预设账户列表（新用户种子数据）
    static let defaultAccounts: [(name: String, type: AccountType, icon: String, color: String)] = [
        ("现金", .cash, "dollarsign", "#22C55E"),
        ("微信", .digital, "wallet.pass", "#07C160"),
        ("支付宝", .digital, "wallet.pass", "#1677FF"),
        ("储蓄卡", .bank, "building.columns", "#6366F1"),
        ("信用卡", .card, "creditcard", "#F59E0B")
    ]

    /// 初始化默认账户数据
    /// 在首次启动时调用，确保用户有可用的账户
    static func seedDefaultAccounts(in context: NSManagedObjectContext) {
        // 检查是否已存在账户
        let fetchRequest = Account.fetchRequest()
        fetchRequest.fetchLimit = 1

        if (try? context.count(for: fetchRequest)) ?? 0 > 0 {
            return // 已有账户，跳过初始化
        }

        // 创建默认账户（第一个设为默认账户）
        for (index, accountData) in defaultAccounts.enumerated() {
            _ = create(
                in: context,
                name: accountData.name,
                type: accountData.type.rawValue,
                isDefault: index == 0,
                icon: accountData.icon,
                color: accountData.color,
                sortOrder: Int16(index)
            )
        }

        // 保存上下文
        try? context.save()
    }

    /// 获取默认账户
    static func getDefaultAccount(in context: NSManagedObjectContext) -> Account? {
        let fetchRequest = Account.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isDefault == true")
        fetchRequest.fetchLimit = 1

        return try? context.fetch(fetchRequest).first
    }

    // MARK: - 存量数据迁移

    /// 确保系统中始终有且仅有一个默认账户
    /// 若无默认账户，自动将第一个未归档账户设为默认
    static func ensureDefaultAccount(in context: NSManagedObjectContext) {
        // 检查是否已有默认账户
        if getDefaultAccount(in: context) != nil {
            return
        }

        // 查找第一个未归档账户
        let fetchRequest = Account.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isArchived == false")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        fetchRequest.fetchLimit = 1

        if let firstAccount = try? context.fetch(fetchRequest).first {
            // 取消所有默认标记（安全措施）
            let allRequest = Account.fetchRequest()
            allRequest.predicate = NSPredicate(format: "isDefault == true")
            if let existingDefaults = try? context.fetch(allRequest) {
                for account in existingDefaults {
                    account.isDefault = false
                }
            }
            firstAccount.isDefault = true
            try? context.save()
        }
    }

    /// 旧用户升级后补齐账户数据
    /// 1. 补齐 sortOrder
    /// 2. 修复默认账户唯一性（多个默认只保留排序最靠前的）
    static func backfillAccounts(in context: NSManagedObjectContext) {
        let fetchRequest = Account.fetchRequest()
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "isDefault", ascending: false),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]

        guard let accounts = try? context.fetch(fetchRequest), !accounts.isEmpty else {
            return
        }

        var hasSeenDefault = false
        for (index, account) in accounts.enumerated() {
            // 补齐 sortOrder
            if account.sortOrder == 0 && index > 0 {
                account.sortOrder = Int16(index)
            }

            // 修复默认账户唯一性
            if account.isDefault {
                if hasSeenDefault {
                    account.isDefault = false
                } else {
                    hasSeenDefault = true
                }
            }
        }

        // 确保 sortOrder 连续
        let sorted = accounts.sorted { $0.sortOrder < $1.sortOrder }
        for (index, account) in sorted.enumerated() {
            account.sortOrder = Int16(index)
        }

        try? context.save()

        // 兜底：确保有默认账户
        ensureDefaultAccount(in: context)
    }
}
