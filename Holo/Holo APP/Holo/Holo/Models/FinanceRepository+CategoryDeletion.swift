//
//  FinanceRepository+CategoryDeletion.swift
//  Holo
//
//  分类删除的统一预检与原子执行（开发方案 §4 / Phase 2）。
//
//  契约：
//  - 预检报告（impact）是唯一事实源，UI 只消费值快照；
//  - 执行入口只收 ID + 值类型指令 + 预期版本指纹，不跨弹层持有托管对象；
//  - 提交前重算快照与提交可用性：版本过期 / 出现未决策冲突即拒绝；
//  - 全部处理在一个 context 事务内，任一失败整体 rollback；
//  - 用户可见删除一律软删除进回收站批次（30 天可恢复），不做物理删除。
//

import Foundation
import CoreData

// MARK: - 执行器（context 可注入，测试直连内存栈）

enum CategoryDeletionExecutor {

    // MARK: 预检

    static func impact(categoryID: UUID, in context: NSManagedObjectContext) throws -> CategoryDeletionImpactSnapshot {
        let sourceRows = try fetchCategoryRows(id: categoryID, in: context)
        let liveSourceRows = sourceRows.filter { $0.deletedAt == nil }
        guard let source = DuplicateRowFilter.deduplicatingCopies(liveSourceRows).first else {
            throw FinanceError.notFound
        }
        let isPrimary = source.parentId == nil

        // 子分类：活行参与去向决策；软删行保留原批次（恢复契约），只计入版本指纹
        let childRows = try fetchChildRows(parentID: categoryID, in: context)
        let liveChildRows = DuplicateRowFilter.deduplicatingCopies(childRows.filter { $0.deletedAt == nil })

        let familyIDs = [categoryID] + liveChildRows.map(\.id)
        let familyIDList = familyIDs as [UUID]

        // 名下明细（活）与回收站计数：按 category.id IN family 匹配，
        // 覆盖挂在 iCloud 重复行上的明细；再去重同 id 明细副本
        let liveTransactions = DuplicateRowFilter.deduplicatingCopies(
            try fetchTransactions(familyIDs: familyIDList, liveOnly: true, in: context)
        )
        let recycledTransactionRows = try fetchTransactions(familyIDs: familyIDList, liveOnly: false, in: context)
            .filter { $0.deletedAt != nil }
        let recycledTransactionCount = Set(recycledTransactionRows.map(\.id)).count

        let budgetRows = try fetchBudgets(familyIDs: familyIDList, in: context)
        let projectRows = try fetchSpendingProjects(familyIDs: familyIDList, in: context)

        let familyNames = Set([source.name] + liveChildRows.map(\.name))
        let learnedMappings = try fetchLearnedMappings(
            typeRaw: source.type,
            names: familyNames,
            in: context
        )

        // 预算账户名（一次性查表）
        var accountNameByID: [UUID: String] = [:]
        let accountIDs = Set(budgetRows.map(\.accountId))
        if !accountIDs.isEmpty {
            let request = Account.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", accountIDs)
            for account in try context.fetch(request) {
                accountNameByID[account.id] = account.name
            }
        }

        let typeMismatched = liveTransactions.filter { $0.type != source.type }.count

        let snapshot = CategoryDeletionImpactSnapshot(
            sourceCategoryID: categoryID,
            sourceRevision: makeRevision(
                sourceRows: sourceRows,
                childRows: childRows,
                liveTransactionCount: liveTransactions.count,
                recycledTransactionCount: recycledTransactionCount,
                budgetCount: budgetRows.count,
                projectCount: projectRows.count,
                mappingCount: learnedMappings.count
            ),
            scope: isPrimary ? .primary : .secondary,
            sourceTypeRaw: source.type,
            childCategories: try liveChildRows.map { child in
                let childFamily = [child.id]
                return CategoryImpactItem(
                    id: child.id,
                    name: child.name,
                    icon: child.icon,
                    colorHex: child.color,
                    transactionTypeRaw: child.type,
                    liveTransactionCount: DuplicateRowFilter.deduplicatingCopies(
                        try fetchTransactions(familyIDs: childFamily, liveOnly: true, in: context)
                    ).count,
                    budgetCount: try fetchBudgets(familyIDs: childFamily, in: context).count,
                    spendingProjectCount: try fetchSpendingProjects(familyIDs: childFamily, in: context).count,
                    learnedMappingCount: try fetchLearnedMappings(
                        typeRaw: child.type, names: [child.name], in: context
                    ).count
                )
            },
            liveTransactions: liveTransactions.map { tx in
                TransactionImpactItem(
                    id: tx.id,
                    date: tx.date,
                    title: tx.note ?? tx.remark ?? String(localized: "无备注"),
                    accountName: tx.account?.name,
                    signedAmount: tx.amountAsDecimal * (tx.type == TransactionType.income.rawValue ? 1 : -1),
                    installmentText: tx.installmentLabel,
                    importSourceText: tx.importSource,
                    typeRaw: tx.type
                )
            },
            recycledTransactionCount: recycledTransactionCount,
            budgets: budgetRows.map { budget in
                BudgetImpactItem(
                    id: budget.id,
                    accountID: budget.accountId,
                    amount: budget.amount as Decimal,
                    periodRaw: budget.period,
                    accountName: accountNameByID[budget.accountId]
                )
            },
            spendingProjects: projectRows.map { project in
                SpendingProjectImpactItem(
                    id: project.id,
                    name: project.name,
                    kindRaw: project.kind,
                    amount: project.amountDecimal,
                    frequencyRaw: project.frequency,
                    isPaused: project.isPaused
                )
            },
            learnedMappings: learnedMappings,
            blockers: typeMismatched > 0 ? [.typeMismatchedTransactions(count: typeMismatched)] : []
        )
        return snapshot
    }

    // MARK: 决策上下文（选定目标后由 UI 现查）

    static func submissionContext(
        for disposition: CategoryDeletionDisposition,
        in context: NSManagedObjectContext
    ) throws -> CategoryDeletionPolicy.SubmissionContext {
        switch disposition {
        case .secondary(.moveAll(let targetID, _)):
            return CategoryDeletionPolicy.SubmissionContext(
                targetBudgetProbes: try targetBudgetProbes(categoryID: targetID, in: context),
                targetSiblingNames: []
            )
        case .primary(.moveChildren(let targetParentID, _)):
            let siblings = try fetchChildRows(parentID: targetParentID, in: context)
                .filter { $0.deletedAt == nil }
            return CategoryDeletionPolicy.SubmissionContext(
                targetBudgetProbes: [],
                targetSiblingNames: DuplicateRowFilter.deduplicatingCopies(siblings).map(\.name)
            )
        default:
            return CategoryDeletionPolicy.SubmissionContext()
        }
    }

    // MARK: 执行

    static func execute(_ command: CategoryDeletionCommand, in context: NSManagedObjectContext) throws {
        let now = Date()

        // 1. 重算预检并校验版本指纹：处理页打开期间数据被改（CloudKit 合并/他端操作）即拒绝
        let snapshot = try impact(categoryID: command.sourceCategoryID, in: context)
        guard snapshot.sourceRevision == command.expectedRevision else {
            throw FinanceError.staleCategoryDeletion
        }

        // 2. 重验提交可用性（目标侧冲突可能已变化）
        let submissionContext = try submissionContext(
            for: command.disposition,
            in: context
        )
        let blockers = CategoryDeletionPolicy.submissionBlockers(
            snapshot: snapshot,
            command: command,
            context: submissionContext
        )
        guard blockers.isEmpty else {
            throw FinanceError.categoryDeletionBlocked
        }

        // 3. 回收站批次（与模块清空共用展示/恢复/30 天清理链路）
        let batch = RecycleBinService.makeSingleItemBatch(
            module: .finance,
            summary: batchSummary(for: command, snapshot: snapshot, in: context),
            context: context,
            now: now
        )

        do {
            try apply(command.disposition, snapshot: snapshot, batch: batch, now: now, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - 处理实现

    private static func apply(
        _ disposition: CategoryDeletionDisposition,
        snapshot: CategoryDeletionImpactSnapshot,
        batch: RecycleBinBatch,
        now: Date,
        in context: NSManagedObjectContext
    ) throws {
        switch disposition {
        case .secondary(let secondary):
            try applySecondary(
                secondary,
                toFamilyIDs: snapshot.sourceFamilyIDs,
                familyName: try sourceName(snapshot, in: context),
                snapshot: snapshot,
                batch: batch,
                now: now,
                in: context
            )
            // 源分类全部活行软删进批次
            try softDeleteCategoryRows(id: snapshot.sourceCategoryID, batch: batch, now: now, in: context)

        case .primary(.moveChildren(let targetParentID, let conflicts)):
            try applyPrimaryMove(
                targetParentID: targetParentID,
                conflicts: conflicts,
                snapshot: snapshot,
                batch: batch,
                now: now,
                in: context
            )

        case .primary(.disposeChildren(let childDispositions)):
            for child in snapshot.childCategories {
                let secondary = childDispositions[child.id] ?? .deleteWithReferences
                try applySecondary(
                    secondary,
                    toFamilyIDs: [child.id],
                    familyName: child.name,
                    snapshot: snapshot,
                    batch: batch,
                    now: now,
                    in: context
                )
                try softDeleteCategoryRows(id: child.id, batch: batch, now: now, in: context)
            }
            // 一级名下的规则（targetPrimary 指向源）随整组删除
            try rewriteLearnedRules(
                typeRaw: snapshot.sourceTypeRaw,
                primaryRename: [:],
                subRename: [:],
                deleteNames: [try sourceName(snapshot, in: context)],
                now: now,
                in: context
            )
            try softDeleteCategoryRows(id: snapshot.sourceCategoryID, batch: batch, now: now, in: context)
        }
    }

    /// 二级级处理：对「一个家族 id 集合 + 家族名」执行转移或整删。
    /// 一级整组删除时按子分类逐个复用，批次共用。
    private static func applySecondary(
        _ disposition: SecondaryCategoryDisposition,
        toFamilyIDs familyIDs: Set<UUID>,
        familyName: String,
        snapshot: CategoryDeletionImpactSnapshot,
        batch: RecycleBinBatch,
        now: Date,
        in context: NSManagedObjectContext
    ) throws {
        let familyIDList = Array(familyIDs)

        switch disposition {
        case .moveAll(let targetID, let budgetConflicts):
            guard let target = try fetchLiveCategory(id: targetID, in: context) else {
                throw FinanceError.notFound
            }
            // 目标必须是二级分类；「待分类」有父级挂靠，同样满足
            guard target.parentId != nil else {
                throw FinanceError.subCategoryRequired
            }

            // 明细改指（含回收站中的历史明细，保证未来恢复可用）
            for tx in try fetchTransactions(familyIDs: familyIDList, liveOnly: false, in: context) {
                tx.category = target
            }

            // 预算：无冲突改指；冲突按用户决策（合并金额=并入目标后移除；保留目标=进批次）
            let movingBudgets = try fetchBudgets(familyIDs: familyIDList, in: context)
            let targetProbes = try targetBudgetProbes(categoryID: targetID, in: context)
            let conflictIDs = Set(CategoryDeletionPolicy.budgetConflicts(
                moving: movingBudgets.map { budget in
                    BudgetConflictProbe(
                        budgetID: budget.id, accountID: budget.accountId, periodRaw: budget.period
                    )
                },
                intoTarget: targetProbes
            ).map(\.budgetID))
            for budget in movingBudgets {
                if conflictIDs.contains(budget.id),
                   budgetConflicts[budget.id] == .mergeAmounts {
                    guard let targetBudget = targetProbes.first(where: { probe in
                        probe.accountID == budget.accountId && probe.periodRaw == budget.period
                    }).flatMap({ probe in
                        try? fetchBudgetRows(id: probe.budgetID, in: context).first
                    }) else {
                        // 决策依据的目标预算已不存在（提交前被删）：按未决策冲突拒绝
                        throw FinanceError.categoryDeletionBlocked
                    }
                    targetBudget.amount = targetBudget.amount.adding(budget.amount)
                    for row in try fetchBudgetRows(id: budget.id, in: context) {
                        context.delete(row)
                    }
                } else if conflictIDs.contains(budget.id) {
                    // 保留目标：被转移预算随分类进批次
                    for row in try fetchBudgetRows(id: budget.id, in: context) where row.deletedAt == nil {
                        row.markDeleted(batchId: batch.id, at: now)
                    }
                } else {
                    for row in try fetchBudgetRows(id: budget.id, in: context) {
                        row.categoryId = targetID
                    }
                }
            }

            // 固定支出改指，未来自动记账继续生效
            for project in try fetchSpendingProjects(familyIDs: familyIDList, in: context) {
                project.categoryId = targetID
            }

            // 学习规则改写指向目标（名称制存储，改写文本即改指）：
            // 二级名映射到目标名，且仅 targetSub 命中的行跟随改写一级名（源父→目标父），
            // 避免误伤仍留在源父下其他子分类的规则
            let sourceParentName = try parentName(of: snapshot.sourceCategoryID, in: context)
            let targetParentName = try parentName(of: targetID, in: context)
            var primaryRename: [String: String] = [:]
            if let source = sourceParentName, let target = targetParentName, source != target {
                primaryRename[source] = target
            }
            try rewriteLearnedRules(
                typeRaw: snapshot.sourceTypeRaw,
                primaryRename: primaryRename,
                subRename: [familyName: target.name],
                deleteNames: [],
                now: now,
                in: context
            )

        case .deleteWithReferences:
            // 活明细与关联配置进入同一批次；回收站中的旧批次数据保持原批次不动
            //（旧明细恢复时恢复引擎会联动复活同批分类；到期时序上旧数据先于新批次清理）
            for tx in try fetchTransactions(familyIDs: familyIDList, liveOnly: false, in: context)
            where tx.deletedAt == nil {
                tx.markDeleted(batchId: batch.id, at: now)
            }
            for budget in try fetchBudgets(familyIDs: familyIDList, in: context)
            where budget.deletedAt == nil {
                budget.markDeleted(batchId: batch.id, at: now)
            }
            for project in try fetchSpendingProjects(familyIDs: familyIDList, in: context)
            where project.deletedAt == nil {
                project.markDeleted(batchId: batch.id, at: now)
            }
            // 规则物理删除：CloudKit 同步删除；未上线设备回流的旧副本命中时
            // 现场按名称找不到分类即静默 miss，不构成悬空引用
            try rewriteLearnedRules(
                typeRaw: snapshot.sourceTypeRaw,
                primaryRename: [:],
                subRename: [:],
                deleteNames: [familyName],
                now: now,
                in: context
            )
        }
    }

    /// 一级迁移：子分类改挂目标父，账目/预算/固定支出仍指原二级（语义损失最小）
    private static func applyPrimaryMove(
        targetParentID: UUID,
        conflicts: [UUID: ChildConflictResolution],
        snapshot: CategoryDeletionImpactSnapshot,
        batch: RecycleBinBatch,
        now: Date,
        in context: NSManagedObjectContext
    ) throws {
        guard let targetParent = try fetchLiveCategory(id: targetParentID, in: context) else {
            throw FinanceError.notFound
        }

        let liveSiblings = DuplicateRowFilter.deduplicatingCopies(
            try fetchChildRows(parentID: targetParentID, in: context).filter { $0.deletedAt == nil }
        )
        var takenNames = Set(liveSiblings.map(\.name))
        let siblingByidName = Dictionary(
            liveSiblings.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first } // iCloud 副本天然同名，保留首个
        )

        for child in snapshot.childCategories {
            if let existing = siblingByidName[child.name],
               conflicts[child.id] == .mergeIntoExisting {
                // 合并：该子分类名下全部引用改挂已有同名分类，冲突行进批次
                try applySecondary(
                    .moveAll(toCategoryID: existing.id, budgetConflicts: [:]),
                    toFamilyIDs: [child.id],
                    familyName: child.name,
                    snapshot: snapshot,
                    batch: batch,
                    now: now,
                    in: context
                )
                try softDeleteCategoryRows(id: child.id, batch: batch, now: now, in: context)
            } else {
                // 保留两个：冲突子分类重命名为唯一名后整体迁移
                let newName = CategoryDeletionPolicy.renamedChild(baseName: child.name, takenNames: takenNames)
                for row in try fetchCategoryRows(id: child.id, in: context) where row.deletedAt == nil {
                    row.parentId = targetParentID
                    row.color = targetParent.color
                    if newName != child.name { row.name = newName }
                }
                takenNames.insert(newName)
            }
        }

        // 学习规则：源一级名改写为目标一级名；合并子分类名已随 applySecondary 改写
        try rewriteLearnedRules(
            typeRaw: snapshot.sourceTypeRaw,
            primaryRename: [try sourceName(snapshot, in: context): targetParent.name],
            subRename: [:],
            deleteNames: [],
            now: now,
            in: context
        )

        try softDeleteCategoryRows(id: snapshot.sourceCategoryID, batch: batch, now: now, in: context)
    }

    // MARK: - 学习规则统一改写

    /// 名称制规则治理：改写优先于删除；targetSub 命中改写/删除集，或 targetPrimary
    /// 命中删除集的行按映射处理。同 type 才匹配，防止跨收支类型误伤同名分类。
    private static func rewriteLearnedRules(
        typeRaw: String,
        primaryRename: [String: String],
        subRename: [String: String],
        deleteNames: Set<String>,
        now: Date,
        in context: NSManagedObjectContext
    ) throws {
        guard !primaryRename.isEmpty || !subRename.isEmpty || !deleteNames.isEmpty else { return }

        let nameSet = Set(primaryRename.keys)
            .union(subRename.keys)
            .union(deleteNames)

        let mappingRequest = CategoryMappingRecordEntity.fetchRequest()
        mappingRequest.predicate = NSPredicate(
            format: "transactionType == %@ AND (targetPrimary IN %@ OR targetSub IN %@)",
            typeRaw, nameSet, nameSet
        )
        for record in try context.fetch(mappingRequest) {
            if deleteNames.contains(record.targetSub) || deleteNames.contains(record.targetPrimary) {
                context.delete(record)
                continue
            }
            if let newSub = subRename[record.targetSub] {
                record.targetSub = newSub
                if let newPrimary = primaryRename[record.targetPrimary] {
                    record.targetPrimary = newPrimary
                }
            } else if let newPrimary = primaryRename[record.targetPrimary] {
                record.targetPrimary = newPrimary
            } else {
                continue
            }
            record.updatedAt = now
        }

        let ruleRequest = CategoryInductionRuleEntity.fetchRequest()
        ruleRequest.predicate = NSPredicate(
            format: "transactionType == %@ AND (targetPrimary IN %@ OR targetSub IN %@)",
            typeRaw, nameSet, nameSet
        )
        for rule in try context.fetch(ruleRequest) {
            if deleteNames.contains(rule.targetSub) || deleteNames.contains(rule.targetPrimary) {
                context.delete(rule)
                continue
            }
            if let newSub = subRename[rule.targetSub] {
                rule.targetSub = newSub
                if let newPrimary = primaryRename[rule.targetPrimary] {
                    rule.targetPrimary = newPrimary
                }
            } else if let newPrimary = primaryRename[rule.targetPrimary] {
                rule.targetPrimary = newPrimary
            } else {
                continue
            }
            rule.updatedAt = now
        }
    }

    // MARK: - 版本指纹

    private static func makeRevision(
        sourceRows: [Category],
        childRows: [Category],
        liveTransactionCount: Int,
        recycledTransactionCount: Int,
        budgetCount: Int,
        projectCount: Int,
        mappingCount: Int
    ) -> CategoryDeletionRevision {
        // 家族指纹：全部行（含 iCloud 副本与软删行）的身份+内容摘要。
        // FNV-1a 稳定散列——Swift hashValue 每次启动随机化，不用于跨进程比较
        var fingerprints: [String] = []
        for row in sourceRows + childRows {
            fingerprints.append(
                "\(row.id.uuidString)|\(row.parentId?.uuidString ?? "-")|\(row.name)|\(row.icon)|\(row.color)|\(row.type)|\(row.isSystem)|\(row.deletedAt.map { Int($0.timeIntervalSince1970) } ?? -1)"
            )
        }
        fingerprints.sort()
        let familyFingerprint = Self.stableHash(fingerprints.joined(separator: ";"))
        let referenceSummary = "tx\(liveTransactionCount)/rtx\(recycledTransactionCount)/bg\(budgetCount)/pj\(projectCount)/lm\(mappingCount)/rows\(sourceRows.count + childRows.count)"
        return CategoryDeletionRevision(familyFingerprint: familyFingerprint, referenceSummary: referenceSummary)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - 批次摘要

    private static func batchSummary(
        for command: CategoryDeletionCommand,
        snapshot: CategoryDeletionImpactSnapshot,
        in context: NSManagedObjectContext
    ) -> String {
        let sourceName = (try? sourceName(snapshot, in: context)) ?? ""
        switch command.disposition {
        case .secondary(.moveAll(let targetID, _)):
            let targetName = (try? fetchLiveCategory(id: targetID, in: context)?.name) ?? ""
            return String(localized: "删除分类「\(sourceName)」· \(snapshot.liveTransactions.count) 笔已转移到「\(targetName)」")
        case .secondary(.deleteWithReferences):
            return String(localized: "删除分类「\(sourceName)」及 \(snapshot.liveTransactions.count) 笔账目")
        case .primary(.moveChildren):
            return String(localized: "删除分组「\(sourceName)」· \(snapshot.childCategories.count) 个子分类已迁移")
        case .primary(.disposeChildren(let dispositions)):
            let moved = dispositions.values.filter {
                if case .moveAll = $0 { return true }
                return false
            }.count
            return String(localized: "删除分组「\(sourceName)」及 \(snapshot.childCategories.count) 个子分类（\(moved) 个已转移）")
        }
    }

    // MARK: - 查询

    private static func sourceName(
        _ snapshot: CategoryDeletionImpactSnapshot,
        in context: NSManagedObjectContext
    ) throws -> String {
        try fetchLiveCategory(id: snapshot.sourceCategoryID, in: context)?.name ?? ""
    }

    /// 二级分类的父分类名（一级返回 nil）
    private static func parentName(
        of categoryID: UUID,
        in context: NSManagedObjectContext
    ) throws -> String? {
        guard let child = try fetchLiveCategory(id: categoryID, in: context),
              let parentID = child.parentId else { return nil }
        return try fetchLiveCategory(id: parentID, in: context)?.name
    }

    private static func fetchLiveCategory(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> Category? {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request)).first
    }

    private static func fetchCategoryRows(id: UUID, in context: NSManagedObjectContext) throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private static func fetchChildRows(parentID: UUID, in context: NSManagedObjectContext) throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "parentId == %@", parentID as CVarArg)
        return try context.fetch(request)
    }

    private static func fetchTransactions(
        familyIDs: [UUID],
        liveOnly: Bool,
        in context: NSManagedObjectContext
    ) throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        var predicates = [NSPredicate(format: "category.id IN %@", familyIDs)]
        if liveOnly {
            predicates.append(NSPredicate(format: "deletedAt == nil"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try context.fetch(request)
    }

    private static func fetchBudgets(familyIDs: [UUID], in context: NSManagedObjectContext) throws -> [Budget] {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(
            format: "categoryId IN %@ AND deletedAt == nil", familyIDs
        )
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
    }

    private static func fetchBudgetRows(id: UUID, in context: NSManagedObjectContext) throws -> [Budget] {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private static func fetchSpendingProjects(
        familyIDs: [UUID],
        in context: NSManagedObjectContext
    ) throws -> [SpendingProject] {
        let request = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
        request.predicate = NSPredicate(
            format: "categoryId IN %@ AND deletedAt == nil", familyIDs
        )
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
    }

    private static func fetchLearnedMappings(
        typeRaw: String,
        names: Set<String>,
        in context: NSManagedObjectContext
    ) throws -> [LearnedMappingImpactItem] {
        guard !names.isEmpty else { return [] }
        var items: [LearnedMappingImpactItem] = []
        let nameList = Array(names)

        let mappingRequest = CategoryMappingRecordEntity.fetchRequest()
        mappingRequest.predicate = NSPredicate(
            format: "transactionType == %@ AND (targetPrimary IN %@ OR targetSub IN %@)",
            typeRaw, nameList, nameList
        )
        for record in try context.fetch(mappingRequest) {
            items.append(LearnedMappingImpactItem(
                id: record.mappingKey,
                kind: .exactMapping,
                displayText: String(localized: "「\(record.candidate)」→ \(record.targetPrimary) / \(record.targetSub)")
            ))
        }

        let ruleRequest = CategoryInductionRuleEntity.fetchRequest()
        ruleRequest.predicate = NSPredicate(
            format: "transactionType == %@ AND (targetPrimary IN %@ OR targetSub IN %@)",
            typeRaw, nameList, nameList
        )
        for rule in try context.fetch(ruleRequest) {
            items.append(LearnedMappingImpactItem(
                id: rule.ruleKey,
                kind: .inductionRule,
                displayText: String(localized: "规则「\(rule.pattern)」→ \(rule.targetPrimary) / \(rule.targetSub)")
            ))
        }
        return items
    }

    private static func targetBudgetProbes(
        categoryID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [BudgetConflictProbe] {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(
            format: "categoryId == %@ AND deletedAt == nil", categoryID as CVarArg
        )
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            .map { budget in
                BudgetConflictProbe(
                    budgetID: budget.id,
                    accountID: budget.accountId,
                    periodRaw: budget.period
                )
            }
    }

    /// 分类软删除：该 id 的全部活行打标（含 iCloud 副本，只删单行会留幽灵行继续占位）；
    /// 已在回收站的行保持原批次（恢复契约）
    private static func softDeleteCategoryRows(
        id: UUID,
        batch: RecycleBinBatch,
        now: Date,
        in context: NSManagedObjectContext
    ) throws {
        for row in try fetchCategoryRows(id: id, in: context) where row.deletedAt == nil {
            row.markDeleted(batchId: batch.id, at: now)
        }
    }
}

// MARK: - 仓库包装（生产入口）

extension FinanceRepository {

    /// 分类删除预检：引用全景 + 版本指纹 + 预检阻塞项
    func categoryDeletionImpact(categoryID: UUID) async throws -> CategoryDeletionImpactSnapshot {
        try CategoryDeletionExecutor.impact(categoryID: categoryID, in: context)
    }

    /// 选定转移目标后的决策上下文（目标预算探针 / 目标父下子分类名）
    func categoryDeletionSubmissionContext(
        for disposition: CategoryDeletionDisposition
    ) async throws -> CategoryDeletionPolicy.SubmissionContext {
        try CategoryDeletionExecutor.submissionContext(for: disposition, in: context)
    }

    /// 原子执行分类删除；版本过期或存在未决策冲突时抛错且不产生任何写入
    func executeCategoryDeletion(_ command: CategoryDeletionCommand) async throws {
        try CategoryDeletionExecutor.execute(command, in: context)
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    /// 转移目标候选（值快照）：同类型二级分类，排除源家族；「待分类」置顶由 UI 排序
    func categoryMoveCandidates(
        excluding sourceFamilyIDs: Set<UUID>,
        type: TransactionType
    ) async throws -> [CategoryMoveCandidate] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let all = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
        // iCloud 副本天然重复 id，聚合必须 uniquingKeysWith
        let nameByID = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return all.compactMap { category in
            guard category.parentId != nil,
                  category.transactionType == type,
                  !sourceFamilyIDs.contains(category.id) else { return nil }
            return CategoryMoveCandidate(
                id: category.id,
                name: category.name,
                icon: category.icon,
                colorHex: category.color,
                transactionTypeRaw: category.type,
                isSystem: category.isSystem,
                parentID: category.parentId,
                parentName: category.parentId.flatMap { nameByID[$0] }
            )
        }
    }
}
