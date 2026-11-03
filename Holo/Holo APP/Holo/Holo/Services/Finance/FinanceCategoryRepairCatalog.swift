import Foundation

@MainActor
enum FinanceCategoryRepairCatalog {
    static func standardHierarchies() -> [FinanceCategoryRepairHierarchy] {
        func snapshot(_ groups: [Category.LocalizedCategoryGroupDef], type: String) -> [FinanceCategoryRepairHierarchy] {
            groups.map { group in
                FinanceCategoryRepairHierarchy(type: type,
                    parentNames: Set([group.term.hans, group.term.hant, group.term.english].map(normalized)),
                    childNames: Set(group.children.flatMap {
                        [$0.term.hans, $0.term.hant, $0.term.english].map(normalized)
                    }),
                    childIcons: Dictionary(group.children.flatMap { child in
                        [child.term.hans, child.term.hant, child.term.english].map { (normalized($0), Set([child.icon])) }
                    }, uniquingKeysWith: { $0.union($1) }), color: group.color)
            }
        }
        return snapshot(Category.localizedExpenseHierarchy, type: TransactionType.expense.rawValue)
            + snapshot(Category.localizedIncomeHierarchy, type: TransactionType.income.rawValue)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
