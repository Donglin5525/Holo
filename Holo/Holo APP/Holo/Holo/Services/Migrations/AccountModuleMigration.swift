import CoreData
import Foundation
import OSLog

private let accountMigrationLogger = Logger(subsystem: "com.holo.app", category: "AccountModuleMigration")

/// 账户模块升级一次性迁移：信用卡账户类型拆分。
///
/// 旧版只有 `.card` 类型混用储蓄卡和信用卡。现在拆成 `.creditCard` / `.debitCard`。
/// 迁移规则：系统预置的「信用卡」账户（name == "信用卡"）→ `.creditCard`；其余 `.card` → `.debitCard`。
/// 采用 UserDefaults 闸门，幂等执行一次。
enum AccountModuleMigration {
    private static let completionKey = "holo.migration.accountModule.v1"

    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: completionKey) else { return }
        await CoreDataStack.shared.waitUntilReady()

        let context = CoreDataStack.shared.newBackgroundContext()
        do {
            try await context.perform {
                migrateCardAccountType(in: context)
                if context.hasChanges { try context.save() }
            }
            defaults.set(true, forKey: completionKey)
            accountMigrationLogger.info("账户模块迁移完成")
        } catch {
            accountMigrationLogger.warning("账户模块迁移失败，将在下次启动重试：\(error.localizedDescription)")
        }
    }

    /// 将旧的 `.card` 账户拆分为 `.creditCard` / `.debitCard`。
    private static func migrateCardAccountType(in context: NSManagedObjectContext) {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@", "card")
        guard let accounts = try? context.fetch(request), !accounts.isEmpty else { return }

        var changed = 0
        for account in accounts {
            // 系统预置的「信用卡」账户按名迁移；其余 .card 默认归为储蓄卡
            if account.name == "信用卡" {
                account.type = AccountType.creditCard.rawValue
            } else {
                account.type = AccountType.debitCard.rawValue
            }
            account.updatedAt = Date()
            changed += 1
        }
        accountMigrationLogger.info("信用卡账户拆分：迁移 \(changed) 个 .card 账户")
    }
}
