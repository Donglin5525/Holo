import CoreData
import CryptoKit
import Foundation

nonisolated struct CategoryParentRepairItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isDeleted: Bool
}

nonisolated struct CategoryParentRepairTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let type: String
}

/// 只含核对所需的分类与数量，不携带账目正文或托管对象。
nonisolated struct CategoryParentRepairPreview: Identifiable, Equatable, Sendable {
    var id: String { type + ":" + missingParentID.uuidString }
    let missingParentID: UUID
    let type: String
    let items: [CategoryParentRepairItem]
    let activeTransactionCount: Int
    let deletedTransactionCount: Int
    let revision: String

    var activeCategoryCount: Int { items.filter { !$0.isDeleted }.count }
}

/// 只读默认分类目录的纯值快照，可安全交给后台 context。
nonisolated struct FinanceCategoryRepairHierarchy: Sendable {
    let type: String
    let parentNames: Set<String>
    let childNames: Set<String>
    let childIcons: [String: Set<String>]
    let color: String
}

/// 按版本指纹恢复归属，保留分类与记账身份，不按名称合并或删除记录。
nonisolated enum CategoryParentRepairService {
    struct AutomaticResult {
        var repairedGroups = 0
        var repairedCategories = 0
        var deferredGroups = 0
    }

    private struct RollbackReceipt: Codable {
        let revision: String
        let type: String
        let categoryIDs: [UUID]
        let previousParentID: UUID
        let restoredParentID: UUID
    }
    private struct GroupKey: Hashable {
        let parentID: UUID
        let type: String
    }

    static func previews(in context: NSManagedObjectContext, type: String) throws -> [CategoryParentRepairPreview] {
        let request = NSFetchRequest<Category>(entityName: "Category")
        request.returnsObjectsAsFaults = false
        let categories = try context.fetch(request)
        let activeRoots = Set(categories.filter {
            FinanceCategoryIntegrity.isActive($0) && $0.parentId == nil && $0.type == type
        }.map(\.id))
        let groups = Dictionary(grouping: categories.filter {
            FinanceCategoryIntegrity.isActive($0) && $0.type == type && $0.parentId != nil
                && !activeRoots.contains($0.parentId ?? $0.id)
        }, by: { GroupKey(parentID: $0.parentId ?? $0.id, type: $0.type) })

        return try groups.keys.sorted { $0.parentID.uuidString < $1.parentID.uuidString }.map { key in
            // 同一旧父级下的回收站分类一并列入预览；修复不会把它们恢复成活跃状态。
            let rows = categories.filter { $0.parentId == key.parentID && $0.type == key.type }
            let ids = Set(rows.map(\.id))
            let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            txRequest.predicate = NSPredicate(format: "category.id IN %@", Array(ids))
            let transactions = try context.fetch(txRequest)
            let activeIDs = Set(transactions.filter { $0.value(forKey: "deletedAt") == nil }
                .compactMap { $0.value(forKey: "id") as? UUID })
            let deletedIDs = Set(transactions.filter { $0.value(forKey: "deletedAt") != nil }
                .compactMap { $0.value(forKey: "id") as? UUID }).subtracting(activeIDs)
            let items = Dictionary(grouping: rows, by: \.id).map { id, copies in
                let representative = copies.first { FinanceCategoryIntegrity.isActive($0) } ?? copies[0]
                return CategoryParentRepairItem(id: id, name: representative.name,
                                                isDeleted: copies.allSatisfy { !FinanceCategoryIntegrity.isActive($0) })
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            let categoryRevision = rows.map { row in
                [row.objectID.uriRepresentation().absoluteString, row.id.uuidString, row.name,
                 row.type, row.parentId?.uuidString ?? "", (row.value(forKey: "deletedAt") as? Date).map { String($0.timeIntervalSince1970) } ?? ""]
            }.sorted { $0.lexicographicallyPrecedes($1) }
            let transactionRevision = transactions.map { row in
                [row.objectID.uriRepresentation().absoluteString,
                 (row.value(forKey: "id") as? UUID)?.uuidString ?? "",
                 (row.value(forKey: "deletedAt") as? Date).map { String($0.timeIntervalSince1970) } ?? ""]
            }.sorted { $0.lexicographicallyPrecedes($1) }
            let encoder = JSONEncoder()
            let payload = try encoder.encode([categoryRevision, transactionRevision])
            let revision = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            return CategoryParentRepairPreview(missingParentID: key.parentID, type: key.type,
                items: items, activeTransactionCount: activeIDs.count,
                deletedTransactionCount: deletedIDs.count, revision: revision)
        }
    }

    static func targets(from categories: [Category], type: String) -> [CategoryParentRepairTarget] {
        let roots = categories.filter {
            FinanceCategoryIntegrity.isActive($0) && !$0.isSystem && $0.parentId == nil && $0.type == type
        }
        return Dictionary(grouping: roots, by: \.id).compactMap { id, copies in
            guard Set(copies.map(\.name)).count == 1 else { return nil }
            return CategoryParentRepairTarget(id: id, name: copies[0].name, type: type)
        }.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// 只修复原始默认名称、图标、颜色及目录均一致且可唯一还原的缺失父级。
    /// 不依赖用户选择，也不按金额、备注或 AI 推测归属。
    static func repairAutomatically(in context: NSManagedObjectContext,
                                    hierarchies: [FinanceCategoryRepairHierarchy],
                                    receiptDirectory: URL) throws -> AutomaticResult {
        guard !context.hasChanges else { throw FinanceCategoryIntegrityError.unsavedChanges }
        var result = AutomaticResult()
        let previousPolicy = context.mergePolicy
        let previousAuthor = context.transactionAuthor
        context.mergePolicy = NSErrorMergePolicy
        context.transactionAuthor = "finance.categoryParentRepair.automatic.v1"
        defer {
            context.mergePolicy = previousPolicy
            context.transactionAuthor = previousAuthor
        }

        for type in Set(hierarchies.map(\.type)).sorted() {
            for preview in try previews(in: context, type: type) {
                let categories = try context.fetch(NSFetchRequest<Category>(entityName: "Category"))
                let ids = Set(preview.items.map(\.id))
                let rows = categories.filter { ids.contains($0.id) }
                let names = Set(rows.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                // 原父级尚在（包括回收站、错类型或多级）时，不能把同步中间态当成丢失来改挂。
                guard !categories.contains(where: { $0.id == preview.missingParentID }),
                      !names.isEmpty, !rows.isEmpty, rows.allSatisfy({
                          $0.isDefault && !$0.isSystem && $0.parentId == preview.missingParentID && $0.type == type
                      }),
                      Dictionary(grouping: rows, by: \.id).values.allSatisfy({ Set($0.map(\.name)).count == 1 }) else {
                    result.deferredGroups += 1
                    continue
                }
                let matchingHierarchies = hierarchies.filter { hierarchy in
                    hierarchy.type == type && names.isSubset(of: hierarchy.childNames)
                        && rows.allSatisfy { row in
                            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            return hierarchy.childIcons[name]?.contains(row.icon) == true
                                && row.color.lowercased() == hierarchy.color.lowercased()
                        }
                }
                guard matchingHierarchies.count == 1, let hierarchy = matchingHierarchies.first else {
                    result.deferredGroups += 1
                    continue
                }
                let eligibleRootIDs = Set(categories.filter {
                    FinanceCategoryIntegrity.isActive($0) && $0.isDefault && !$0.isSystem && $0.parentId == nil
                        && $0.type == type && hierarchy.parentNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }.map(\.id))
                let eligibleTargets = targets(from: categories, type: type).filter { eligibleRootIDs.contains($0.id) }
                guard eligibleTargets.count == 1, let target = eligibleTargets.first else {
                    result.deferredGroups += 1
                    continue
                }

                let receipt = RollbackReceipt(revision: preview.revision, type: type,
                    categoryIDs: preview.items.map(\.id), previousParentID: preview.missingParentID,
                    restoredParentID: target.id)
                // 回退映射必须先落盘；磁盘不可写时零数据变更，下次后台检查重试。
                try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
                let receiptURL = receiptDirectory.appendingPathComponent(preview.revision + ".json")
                try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
                let changed = try apply(preview, to: target, in: context)
                result.repairedGroups += 1
                result.repairedCategories += changed.count
            }
        }
        return result
    }

    /// 必须在专用、干净的 context 队列执行，避免把其他模块编辑连带保存。
    static func apply(_ preview: CategoryParentRepairPreview, to target: CategoryParentRepairTarget,
                      in context: NSManagedObjectContext) throws -> [NSManagedObjectID] {
        guard !context.hasChanges else { throw FinanceCategoryIntegrityError.unsavedChanges }
        guard let current = try previews(in: context, type: preview.type).first(where: { $0.id == preview.id }),
              current == preview else { throw FinanceCategoryIntegrityError.dataChanged }
        let request = NSFetchRequest<Category>(entityName: "Category")
        let categories = try context.fetch(request)
        guard target.type == preview.type,
              targets(from: categories, type: preview.type).contains(target) else {
            throw FinanceCategoryIntegrityError.invalidTarget
        }
        let ids = Set(preview.items.map(\.id))
        let rows = categories.filter { ids.contains($0.id) }
        guard rows.allSatisfy({ $0.parentId == preview.missingParentID && $0.type == preview.type }) else {
            throw FinanceCategoryIntegrityError.dataChanged
        }
        guard Dictionary(grouping: rows, by: \.id).values.allSatisfy({ Set($0.map(\.name)).count == 1 }) else {
            throw FinanceCategoryIntegrityError.dataChanged
        }
        for row in rows { row.parentId = target.id }
        do { try context.save() }
        catch {
            for row in rows { row.parentId = preview.missingParentID }
            throw error
        }
        return rows.map(\.objectID)
    }
}
