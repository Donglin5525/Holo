//
//  SeedRevivalRepair.swift
//  Holo
//
//  修复「卸载重装后误种的默认账户/分类复活」。
//
//  原理：种子逻辑只凭「本地为空」判断新用户，而重装后 iCloud 恢复的数据要到
//  启动后数分钟才落地，期间老用户被误判为新用户、默认数据被重铺一遍。其中
//  「用户删过的默认项」云端没有对应行，去重合并挤不掉它，于是复活。
//
//  判定铁证：云端回流行的 createdAt 是卸载前写入的时刻，必早于本次种子时刻；
//  一旦发现这种行即为老用户 → 清掉「名字仍在默认清单、从未挂交易/预算/支出
//  项目/子分类、从未被编辑」的种子行。真新用户永远没有铁证，默认数据原样保留。
//

import CoreData
import Foundation
import OSLog

enum SeedRevivalRepair {

    private static let seedTimestampKey = "holo.seed.revival.timestamp.v1"
    /// 未编辑判定容差：种子行创建时 createdAt 与 updatedAt 几乎同刻
    private static let freshEditTolerance: TimeInterval = 60

    private static let logger = Logger(subsystem: "com.holo.app", category: "SeedRevivalRepair")

    /// 种子函数真正创建了默认数据时记录时刻；多次种子取最早，
    /// 保证所有种子行的 createdAt 都不早于该时刻（铁证判定不误伤）
    static func recordSeedMoment() {
        let defaults = UserDefaults.standard
        let now = Date()
        if let existing = defaults.object(forKey: seedTimestampKey) as? Date, existing < now {
            return
        }
        defaults.set(now, forKey: seedTimestampKey)
    }

    /// 云同步远端变更防抖后调用；幂等，无铁证时零写入
    static func repairIfNeeded(context: NSManagedObjectContext) {
        guard let seedMoment = UserDefaults.standard.object(forKey: seedTimestampKey) as? Date else {
            return
        }

        let accountRequest = Account.fetchRequest()
        accountRequest.predicate = NSPredicate(format: "deletedAt == nil")
        let accounts = (try? context.fetch(accountRequest)) ?? []

        let categoryRequest = Category.fetchRequest()
        categoryRequest.includesSubentities = false
        let categories = (try? context.fetch(categoryRequest)) ?? []

        // 铁证：存在创建时间早于本次种子时刻的账户行 = iCloud 已把卸载前的数据带回来
        // （分类实体无时间字段，其动手信号在下方以「交易数据已恢复」单独判定）
        let hasPreexistingAccount = accounts.contains { $0.createdAt < seedMoment }
        guard hasPreexistingAccount else { return }

        // 一次性收集全部引用（预算/支出项目按 id 挂靠），避免逐行查询
        let budgets = (try? context.fetch(Budget.fetchRequest())) ?? []
        let projects = (try? context.fetch(NSFetchRequest<SpendingProject>(entityName: "SpendingProject"))) ?? []
        let budgetAccountRefs = Set(budgets.map(\.accountId))
        let budgetCategoryRefs = Set(budgets.compactMap(\.categoryId))
        let projectAccountRefs = Set(projects.compactMap(\.accountId))
        let projectCategoryRefs = Set(projects.compactMap(\.categoryId))

        var changed = false

        if hasPreexistingAccount {
            let keepNames = Set(Account.defaultAccounts.map(\.name))
            for account in accounts {
                let isFreshSeed = account.createdAt >= seedMoment
                    && account.updatedAt.timeIntervalSince(account.createdAt) <= freshEditTolerance
                guard isFreshSeed,
                      keepNames.contains(account.name),
                      !account.isDefault,
                      (account.transactions ?? []).isEmpty,
                      !budgetAccountRefs.contains(account.id),
                      !projectAccountRefs.contains(account.id)
                else { continue }
                logger.info("清除误种账户：\(account.name, privacy: .public)")
                context.delete(account)
                changed = true
            }
        }

        // 分类实体没有时间字段，无法像账户那样逐行识别种子行；
        // 改用「交易数据已恢复」作为动手信号：用户的交易通常占 iCloud 导入大头，
        // 交易到齐后分类的挂靠判断（交易/预算/项目）才可靠，避免把在用分类误删。
        let transactionRequest = Transaction.fetchRequest()
        transactionRequest.predicate = NSPredicate(format: "createdAt < %@", seedMoment as NSDate)
        transactionRequest.fetchLimit = 1
        let hasPreexistingTransaction = ((try? context.count(for: transactionRequest)) ?? 0) > 0

        if hasPreexistingTransaction {
            let keepNames = Self.defaultCategoryNames
            for category in categories {
                guard keepNames.contains(category.name),
                      !category.isDefault,
                      !category.isSystem,
                      (category.transactions ?? []).isEmpty,
                      !categories.contains(where: { $0.parentId == category.id }),
                      !budgetCategoryRefs.contains(category.id),
                      !projectCategoryRefs.contains(category.id)
                else { continue }
                logger.info("清除误种分类：\(category.name, privacy: .public)")
                context.delete(category)
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
    }

    /// 全部默认分类名称（一级 + 二级 + 系统分类），与种子来源同一份清单
    private static var defaultCategoryNames: Set<String> {
        var names = Set<String>()
        for group in Category.expenseHierarchy + Category.incomeHierarchy {
            names.insert(group.name)
            for child in group.children {
                names.insert(child.name)
            }
        }
        for systemCat in Category.systemCategories {
            names.insert(systemCat.name)
        }
        return names
    }
}
