import Foundation

/// 账单名称与分类的展示规则，独立于 Core Data，避免无名称时重复显示二级科目。
struct FinanceCategoryRowPresentation: Equatable {
    let requiresParentRepair: Bool
    let title: String
    let parentName: String?
    let categoryName: String?

    init(note: String?, categoryName: String?, parentName: String?, requiresParentRepair: Bool = false) {
        self.requiresParentRepair = requiresParentRepair
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNote = !(note?.isEmpty ?? true)
        let category = categoryName.flatMap { $0.isEmpty ? nil : $0 }
        title = hasNote ? (note ?? "") : (category ?? String(localized: "未分类"))
        self.parentName = parentName.flatMap { $0.isEmpty ? nil : $0 }
        self.categoryName = hasNote ? (category ?? String(localized: "未分类")) : nil
    }
}
