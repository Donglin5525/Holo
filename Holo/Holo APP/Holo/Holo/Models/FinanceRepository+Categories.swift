//
//  FinanceRepository+Categories.swift
//  Holo
//
//  分类相关操作
//

import Foundation
import CoreData

// 分类删除的统一入口已迁移至 FinanceRepository+CategoryDeletion.swift：
// 预检（categoryDeletionImpact）+ 原子执行（executeCategoryDeletion），
// 用户可见删除一律软删除进回收站批次，旧的物理删除路径已废弃（开发方案 §5）。

extension FinanceRepository {

    // MARK: - Category Operations
    
    func getAllCategories() async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [
            NSSortDescriptor(key: "type", ascending: true),
            NSSortDescriptor(key: "sortOrder", ascending: true)
        ]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            .sorted(by: Category.precedesInUserOrder)
    }
    
    func getCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "type == %@", type.rawValue),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            .sorted(by: Category.precedesInUserOrder)
    }
    
    /// 获取一级分类（parentId == nil）
    func getTopLevelCategories(by type: TransactionType) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "type == %@ AND parentId == nil", type.rawValue),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            .sorted(by: Category.precedesInUserOrder)
    }
    
    /// 获取指定父分类下的二级子分类
    func getSubCategories(parentId: UUID) async throws -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "parentId == %@", parentId as CVarArg),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            .sorted(by: Category.precedesInUserOrder)
    }
    
    @discardableResult
    func addCategory(
        name: String,
        icon: String,
        color: String,
        type: TransactionType,
        isDefault: Bool = false,
        parentId: UUID? = nil
    ) async throws -> Category {
        let siblings: [Category]
        if let parentId {
            let parentRequest = Category.fetchRequest()
            parentRequest.predicate = NSPredicate(
                format: "id == %@ AND type == %@ AND parentId == nil AND deletedAt == nil",
                parentId as CVarArg, type.rawValue
            )
            parentRequest.fetchLimit = 1
            guard try !context.fetch(parentRequest).isEmpty else {
                throw FinanceCategoryIntegrityError.invalidTarget
            }
            siblings = try await getSubCategories(parentId: parentId)
        } else {
            siblings = try await getTopLevelCategories(by: type)
        }
        var nextRank = Int(siblings.map(\.sortOrder).max() ?? -1) + 1
        if nextRank > Int(Int16.max) {
            guard siblings.count <= Int(Int16.max) else {
                throw FinanceCategoryOrderingError.tooManyCategories
            }
            try reorderCategories(ids: siblings.map(\.id), type: type, parentID: parentId)
            nextRank = siblings.count
        }
        let category = Category.create(
            in: context,
            name: name,
            icon: icon,
            color: color,
            type: type.rawValue,
            isDefault: isDefault,
            sortOrder: Int16(nextRank),
            parentId: parentId
        )
        try context.save()
        return category
    }
    
    /**
     获取最近常用的二级子分类
     
     统计规则：
     1. 查询最近 N 天内的交易记录
     2. 按分类出现频次降序排列
     3. 只返回二级子分类（parentId 非 nil）
     4. 最多返回 limit 个
     
     - Parameters:
       - type: 交易类型（收入/支出）
       - limit: 返回数量上限，默认 8
       - days: 统计的天数窗口，默认 30 天
     - Returns: 按使用频次排序的二级分类数组
     */
    func getRecentCategories(
        type: TransactionType,
        limit: Int = 8,
        days: Int = 30
    ) async throws -> [Category] {
        // 计算时间窗口起点
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        ) ?? Date()
        
        // 查询指定类型、指定时间范围内的所有交易（排除对账调整流水：
        // 它挂的「余额调整」分类不该被使用频次推高、也不该进入记账推荐）
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "date >= %@ AND category.type == %@",
                cutoffDate as NSDate,
                type.rawValue
            ),
            NSPredicate(format: "deletedAt == nil"),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate()
        ])
        
        let transactions = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
        
        // 统计每个分类的使用次数（仅统计二级子分类）
        var frequencyMap: [NSManagedObjectID: Int] = [:]
        var lastUsedMap: [NSManagedObjectID: Date] = [:]
        var categoryMap: [NSManagedObjectID: Category] = [:]
        
        for tx in transactions {
            guard let cat = tx.category, cat.isSubCategory else { continue }
            let oid = cat.objectID
            frequencyMap[oid, default: 0] += 1
            lastUsedMap[oid] = max(lastUsedMap[oid] ?? .distantPast, tx.date)
            categoryMap[oid] = cat
        }
        
        // 频次降序；同频按最近一次使用降序，再按名称——字典遍历顺序不稳定，
        // 没有次级键时同频分类每次打开都会重排
        let sorted = frequencyMap
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lDate = lastUsedMap[lhs.key] ?? .distantPast
                let rDate = lastUsedMap[rhs.key] ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return (categoryMap[lhs.key]?.name ?? "") < (categoryMap[rhs.key]?.name ?? "")
            }
            .prefix(limit)
            .compactMap { categoryMap[$0.key] }
        
        return Array(sorted)
    }
    
    /// 确保「待分类」分类存在，不存在则创建（挂到对应父分类下）。
    /// 不变量：返回的「待分类」永远是二级——父级缺失时补种「其他/其他收入」一级，
    /// 绝不降级为一级（入账闸门只认二级，一级兜底会被自己拦下）。
    func ensurePendingCategory(type: TransactionType) -> Category {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(
            format: "name == %@ AND type == %@ AND parentId != nil",
            FinancePendingCategory.currentName,
            type.rawValue
        )
        if let existing = try? context.fetch(request).first {
            return existing
        }

        let legacyRequest = Category.fetchRequest()
        legacyRequest.predicate = NSPredicate(
            format: "name == %@ AND type == %@ AND parentId != nil",
            FinancePendingCategory.legacyName,
            type.rawValue
        )
        if let legacy = try? context.fetch(legacyRequest).first {
            legacy.name = FinancePendingCategory.currentName
            legacy.icon = "questionmark.circle.fill"
            legacy.color = "#F59E0B"
            legacy.isSystem = true
            try? context.save()
            return legacy
        }

        // 找到对应的父分类（与种子同一词表、同一固化种子语言，保证查重命中）；
        // 回收站里的父级不算存在——入账闸门 validateForBooking 只认未删的活父级
        let parentName = type == .expense
            ? FinanceSeedVocabulary.other.value(for: .seedLanguage)
            : FinanceSeedVocabulary.otherIncome.value(for: .seedLanguage)
        let parentRequest = Category.fetchRequest()
        parentRequest.predicate = NSPredicate(
            format: "name == %@ AND type == %@ AND parentId == nil AND deletedAt == nil",
            parentName, type.rawValue
        )
        let parentId: UUID
        if let existingParentId = (try? context.fetch(parentRequest).first)?.id {
            parentId = existingParentId
        } else {
            // 父级被用户删除/改名时补种一级：「其他 → 待分类」是运行不变量（与系统分类
            // 同待遇，不受「删过的预设不复活」约束）——缺了它，AI 记账的分类兜底会被
            // 入账闸门拦成死路（2026-11-01 用户实报「记账必须选择二级分类」根因）。
            // 外观与种子层级同源，保证按名查重与 UI 展示不漂移。
            parentId = Category.create(
                in: context,
                name: parentName,
                icon: Category.parentIconMapping[parentName] ?? "questionmark.folder.fill",
                color: type == .expense ? "#64748B" : "#A855F7",
                type: type.rawValue,
                isDefault: true,
                sortOrder: 999,
                parentId: nil
            ).id
        }

        let category = Category.create(
            in: context,
            name: FinancePendingCategory.currentName,
            icon: "questionmark.circle.fill",
            color: "#F59E0B",
            type: type.rawValue,
            isDefault: false,
            sortOrder: 999,
            parentId: parentId,
            isSystem: true
        )
        try? context.save()
        return category
    }

    /// 历史 BUG 遗留清理（2026-11-01 实报）：旧版 ensurePendingCategory 在父级缺失时会
    /// 建出一级「待分类/待确认」孤儿行（isSystem 标记）——入账闸门只认二级，这些行永远
    /// 无法用于入账，只会作为顶层垃圾行污染分类选择器。零交易引用的软删；
    /// 有历史交易引用的留置不动（动它等于丢真实账目）。
    /// 特征精确锁定：parentId == nil + isSystem == true + 名字命中兜底词表，
    /// 用户自建的同名一级（isSystem == false）不受影响。
    func softDeleteOrphanPendingCategories() {
        let names = FinanceSeedVocabulary.pending.allValues + [FinancePendingCategory.legacyName]
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(
            format: "name IN %@ AND parentId == nil AND deletedAt == nil AND isSystem == true",
            names
        )
        guard let orphans = try? context.fetch(request), !orphans.isEmpty else { return }

        let now = Date()
        var didChange = false
        for orphan in orphans {
            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSPredicate(
                format: "category.id == %@ AND deletedAt == nil",
                orphan.id as CVarArg
            )
            txRequest.fetchLimit = 1
            guard (try? context.fetch(txRequest))?.isEmpty == true else { continue }
            orphan.markDeleted(batchId: nil, at: now)
            didChange = true
        }
        if didChange {
            try? context.save()
        }
    }

    func updateCategory(_ category: Category, updates: CategoryUpdates) async throws {
        if let name = updates.name { category.name = name }
        if let icon = updates.icon { category.icon = icon }
        if let color = updates.color { category.color = color }
        if let sortOrder = updates.sortOrder { category.sortOrder = sortOrder }
        try context.save()
    }
    
    /// 该分类及其全部二级子分类（含 iCloud 重复行）的 id
    private func categoryIdFamily(of category: Category) throws -> [UUID] {
        var ids = [category.id]
        let subRequest = Category.fetchRequest()
        subRequest.predicate = NSPredicate(format: "parentId == %@", category.id as CVarArg)
        ids += try context.fetch(subRequest).map { $0.id }
        return ids
    }

    /// 仍然有效（未进回收站）且挂在该分类或其二级子分类上的记账明细。
    /// 按 categoryId 匹配而非关系匹配：iCloud 同步会为同一分类产生重复行，
    /// 按关系匹配会漏掉挂在重复行上的明细，造成「明细明明删光了却提示分类被占用」。
    func liveTransactions(referencing category: Category) async throws -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "category.id IN %@", try categoryIdFamily(of: category)),
            NSPredicate(format: "deletedAt == nil")
        ])
        return try context.fetch(request)
    }

    /// 批量清理导入时自动创建的分类（importBatchId 标记）。
    /// 入口在「设置 → 数据管理」；被有效交易占用的分类跳过。
    /// - Returns: (已删除数量, 跳过数量-被交易使用)
    func cleanupImportedCategories() async throws -> (deleted: Int, skipped: Int) {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "importBatchId != nil")
        let importedCategories = try context.fetch(request)

        var deleted = 0
        var skipped = 0

        for category in importedCategories {
            // 检查是否被有效交易使用（软删明细不占位，与单删口径一致）
            let txRequest = Transaction.fetchRequest()
            txRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "category.id == %@", category.id as CVarArg),
                NSPredicate(format: "deletedAt == nil")
            ])
            let inUse = try context.count(for: txRequest) > 0

            if inUse {
                skipped += 1
            } else {
                // 清理同样走软删除批次，可从回收站恢复
                let batch = RecycleBinService.makeSingleItemBatch(
                    module: .finance,
                    summary: String(localized: "清理导入分类「\(category.name)」"),
                    context: context
                )
                let rowRequest = Category.fetchRequest()
                rowRequest.predicate = NSPredicate(format: "id == %@", category.id as CVarArg)
                for row in try context.fetch(rowRequest) {
                    row.markDeleted(batchId: batch.id)
                }
                deleted += 1
            }
        }

        if deleted > 0 {
            try context.save()
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
        }

        return (deleted, skipped)
    }

}
