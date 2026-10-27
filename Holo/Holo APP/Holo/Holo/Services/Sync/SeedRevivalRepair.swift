//
//  SeedRevivalRepair.swift
//  Holo
//
//  修复「卸载重装后误种的默认账户/欢迎笔记复活」；分类身份保留。
//
//  原理：种子逻辑只凭「本地为空」判断新用户，而重装后 iCloud 恢复的数据要到
//  启动后数分钟才落地，期间老用户被误判为新用户、默认数据被重铺一遍。其中
//  「用户删过的默认项」云端没有对应行，去重合并挤不掉它，于是复活。
//
//  判定铁证：云端回流行的 createdAt 是卸载前写入的时刻，必早于本次种子时刻；
//  一旦发现这种行即为老用户，再检查未编辑且无引用的默认账户和欢迎笔记。
//  分类没有可证明来源的时间字段，不能自动按名称清理。
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

        // 铁证：存在创建时间早于本次种子时刻的账户行 = iCloud 已把卸载前的数据带回来
        let hasPreexistingAccount = accounts.contains { $0.createdAt < seedMoment }

        // 欢迎笔记铁证独立判定（Thought 有 createdAt）：存在任何早于种子时刻的
        // 想法行（含软删，卸载前的想法连软删行一起回来）= 老用户回来了。
        // 跨设备场景（第二台设备新装、第一台的想法经 iCloud 恢复）同判。
        let thoughtRequest = Thought.fetchRequest()
        thoughtRequest.predicate = NSPredicate(format: "createdAt < %@", seedMoment as NSDate)
        thoughtRequest.fetchLimit = 1
        let hasPreexistingThought = ((try? context.count(for: thoughtRequest)) ?? 0) > 0

        guard hasPreexistingAccount || hasPreexistingThought else { return }

        // 一次性收集全部引用（预算/支出项目按 id 挂靠），避免逐行查询
        let budgets = (try? context.fetch(Budget.fetchRequest())) ?? []
        let projects = (try? context.fetch(NSFetchRequest<SpendingProject>(entityName: "SpendingProject"))) ?? []
        let budgetAccountRefs = Set(budgets.map(\.accountId))
        let projectAccountRefs = Set(projects.compactMap(\.accountId))

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

        // 分类没有可证明其来源的种子标识或时间字段；“当前没有引用”也无法排除云端迟到引用。
        // 保留分类身份，避免清理时删掉父级、后续同步子分类却仍引用旧 UUID。

        // 欢迎笔记：只清从未被编辑过的 fresh 种子行（铁证见函数开头 Thought 判定）。
        // 用户删过欢迎笔记再重装时：恢复的软删行构成铁证 → 误种的 fresh 行被清，
        // 预设不复活（与「用户删过的默认分类不得复活」同一原则）；用户改过内容的
        // （跨设备同步下来的编辑版）按真实想法保留。
        if hasPreexistingThought {
            let noteRequest = Thought.fetchRequest()
            noteRequest.predicate = NSPredicate(
                format: "id == %@",
                WelcomeNoteSeed.noteId as CVarArg
            )
            for thought in (try? context.fetch(noteRequest)) ?? [] {
                let isFreshSeed = thought.createdAt >= seedMoment
                    && thought.updatedAt.timeIntervalSince(thought.createdAt) <= freshEditTolerance
                guard isFreshSeed else { continue }
                logger.info("清除误种欢迎笔记")
                context.delete(thought)
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
    }

}
