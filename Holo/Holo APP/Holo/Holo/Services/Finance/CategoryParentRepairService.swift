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

/// 先预览、后按版本指纹恢复归属。保留分类与记账身份，不按名称合并或删除任何记录。
nonisolated enum CategoryParentRepairService {
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
