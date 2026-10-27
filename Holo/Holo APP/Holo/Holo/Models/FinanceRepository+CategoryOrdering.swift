import Foundation
import CoreData

extension Category {
    /// 历史分类可能有相同权重，以稳定 ID 打破平局，防止页面刷新后顺序漂移。
    static func precedesInUserOrder(_ lhs: Category, _ rhs: Category) -> Bool {
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum FinanceCategoryOrderingError: LocalizedError {
    case categoriesChanged
    case tooManyCategories

    var errorDescription: String? {
        switch self {
        case .categoriesChanged:
            return String(localized: "分类已发生变化，请重试排序。")
        case .tooManyCategories:
            return String(localized: "当前分类数量过多，无法保存排序。")
        }
    }
}

extension FinanceRepository {
    /// 一次只保存同收支类型、同父级的完整顺序；同步副本一并更新，历史归属不变。
    func reorderCategories(ids: [UUID], type: TransactionType, parentID: UUID?) throws {
        guard ids.count <= Int(Int16.max) + 1 else {
            throw FinanceCategoryOrderingError.tooManyCategories
        }
        let request = Category.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "type == %@ AND deletedAt == nil", type.rawValue),
            parentID.map { NSPredicate(format: "parentId == %@", $0 as CVarArg) }
                ?? NSPredicate(format: "parentId == nil")
        ])
        let rows = try context.fetch(request)
        let requestedIDs = Set(ids)
        guard requestedIDs.count == ids.count, requestedIDs == Set(rows.map(\.id)) else {
            throw FinanceCategoryOrderingError.categoriesChanged
        }
        let ranks = Dictionary(ids.enumerated().map { ($0.element, Int16($0.offset)) },
                               uniquingKeysWith: { first, _ in first })
        guard rows.contains(where: { ranks[$0.id] != $0.sortOrder }) else { return }
        let previous = rows.map { ($0, $0.sortOrder) }
        for row in rows {
            if let rank = ranks[row.id] { row.sortOrder = rank }
        }
        do {
            try context.save()
        } catch {
            // 不回滚整个共享上下文，避免撤销其他模块尚未保存的编辑。
            for (row, rank) in previous { row.sortOrder = rank }
            throw error
        }
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }
}
