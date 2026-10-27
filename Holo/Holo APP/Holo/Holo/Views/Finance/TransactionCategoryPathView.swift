import SwiftUI

/// 分类独占一行，二级科目优先获得空间，不被名称、备注或账户挤掉。
struct TransactionCategoryPathView: View {
    let presentation: FinanceCategoryRowPresentation

    var body: some View {
        if presentation.parentName != nil || presentation.categoryName != nil || presentation.requiresParentRepair {
            HStack(spacing: HoloSpacing.xs) {
                if let parentName = presentation.parentName {
                    Text(parentName)
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                if presentation.parentName != nil && presentation.categoryName != nil {
                    Image(systemName: "chevron.right")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                        .accessibilityHidden(true)
                }
                if let categoryName = presentation.categoryName {
                    Text(categoryName)
                        .fontWeight(.medium)
                        .foregroundColor(.holoToolText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if presentation.requiresParentRepair {
                    Text("归属待修复")
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                }
            }
            .font(.holoLabel)
            .accessibilityElement(children: .combine)
        }
    }
}
