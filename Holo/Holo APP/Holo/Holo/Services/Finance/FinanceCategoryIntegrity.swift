import CoreData
import Foundation

enum FinanceCategoryIntegrityError: LocalizedError {
    case missingParent
    case dataChanged
    case invalidTarget
    case unsavedChanges

    var errorDescription: String? {
        switch self {
        case .missingParent:
            return String(localized: "这个分类暂时不可用，请稍后重试。")
        case .dataChanged:
            return String(localized: "分类或关联记录已发生变化，本次操作未执行。")
        case .invalidTarget:
            return String(localized: "当前没有可确认的有效一级分类。")
        case .unsavedChanges:
            return String(localized: "存在尚未保存的数据，本次操作未执行。")
        }
    }
}

/// 分类可用性由真实父级身份决定，不能仅凭有 parentId 或同名就判为可入账。
nonisolated enum FinanceCategoryIntegrity {
    /// 调用方必须在对象所属 context 队列执行；通过 KVC 读取由软删扩展声明的字段。
    static func isActive(_ category: Category) -> Bool {
        category.managedObjectContext != nil && !category.isDeleted && category.value(forKey: "deletedAt") == nil
    }

    private struct ParentKey: Hashable {
        let id: UUID
        let type: String
    }

    static func selectableCategories(in categories: [Category], type: String? = nil) -> [Category] {
        let active = categories.filter {
            isActive($0) && (type == nil || $0.type == type)
        }
        let parents = Set(active.filter { $0.parentId == nil }.map { ParentKey(id: $0.id, type: $0.type) })
        return active.filter { category in
            guard let parentID = category.parentId else { return true }
            guard parentID != category.id else { return false }
            return parents.contains(ParentKey(id: parentID, type: category.type))
        }
    }

    /// 一级统计只接受活跃、同类型的真实一级；缺失关系由修复入口处理。
    static func topLevelCategory(for category: Category, roots: [UUID: Category]) -> Category? {
        guard isActive(category) else { return nil }
        let rootID = category.parentId ?? category.id
        guard let root = roots[rootID], isActive(root),
              root.parentId == nil, root.type == category.type else { return nil }
        return root
    }

    /// 写入边界使用一次精确查询；父级晚到时保留历史数据，暂不接受新的入账引用。
    static func validateForBooking(_ category: Category, in context: NSManagedObjectContext) throws {
        guard category.managedObjectContext === context, isActive(category), let parentID = category.parentId, parentID != category.id else {
            throw FinanceCategoryIntegrityError.missingParent
        }
        let request = NSFetchRequest<Category>(entityName: "Category")
        request.predicate = NSPredicate(
            format: "id == %@ AND type == %@ AND parentId == nil AND deletedAt == nil",
            parentID as CVarArg, category.type
        )
        request.fetchLimit = 1
        guard try !context.fetch(request).isEmpty else { throw FinanceCategoryIntegrityError.missingParent }
    }
}
