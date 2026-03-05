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
        isDefault: Bool = false
    ) -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.name = name
        account.type = type
        account.isDefault = isDefault
        
        return account
    }
    
    // MARK: - Default Accounts
    
    /// 预设账户列表
    static let defaultAccounts = [
        (name: "现金", type: AccountType.cash),
        (name: "微信", type: AccountType.digital),
        (name: "支付宝", type: AccountType.digital),
        (name: "信用卡", type: AccountType.card)
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
                isDefault: index == 0
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
}