import CoreData
import Foundation
import OSLog

private let accountMigrationLogger = Logger(subsystem: "com.holo.app", category: "AccountModuleMigration")

/// 账户模块升级迁移：信用卡账户类型拆分。
///
/// 旧版只有 `.card` 类型混用储蓄卡和信用卡。现在拆成 `.creditCard` / `.bank`。
/// 迁移规则：系统预置的「信用卡」账户（name == "信用卡"）→ `.creditCard`；其余 `.card` → `.bank`。
///
/// 采用幂等扫描（非 UserDefaults 闸门）：每次启动都扫一遍，发现 `card`/`debitCard` 类型就修正，
/// 没有则什么也不做。这样即使类型定义多次调整也能持续收敛，不会因为闸门已标记而漏修。
enum AccountModuleMigration {

    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard) async {
        await CoreDataStack.shared.waitUntilReady()

        let context = CoreDataStack.shared.newBackgroundContext()
        do {
            try await context.perform {
                migrateLegacyCardTypes(in: context)
                if context.hasChanges { try context.save() }
            }
        } catch {
            accountMigrationLogger.warning("账户模块迁移失败，将在下次启动重试：\(error.localizedDescription)")
        }
    }

    /// 将旧的 `.card` / `.debitCard` 账户修正为新类型。
    /// - `.card` + 名字是"信用卡" → `.creditCard`
    /// - `.card` 其他 + `.debitCard`（曾短暂存在过的中间态）→ `.bank`
    private static func migrateLegacyCardTypes(in context: NSManagedObjectContext) {
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@ OR type == %@", "card", "debitCard")
        guard let accounts = try? context.fetch(request), !accounts.isEmpty else { return }

        var changed = 0
        for account in accounts {
            if account.type == "card" && account.name == "信用卡" {
                account.type = AccountType.creditCard.rawValue
            } else {
                // 其余旧 .card 和中间态 .debitCard 统一归入储蓄卡
                account.type = AccountType.bank.rawValue
            }
            account.updatedAt = Date()
            changed += 1
        }
        accountMigrationLogger.info("信用卡账户拆分：修正 \(changed) 个历史类型账户")
    }
}
