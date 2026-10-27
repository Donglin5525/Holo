import SwiftUI

struct CategoryParentRepairSection: View {
    let previews: [CategoryParentRepairPreview]
    let onSelect: (CategoryParentRepairPreview) -> Void

    var body: some View {
        Section("归属待修复") {
            ForEach(previews) { preview in
                Button { onSelect(preview) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                            Text(preview.items.filter { !$0.isDeleted }.map(\.name).joined(separator: "、"))
                                .foregroundColor(.holoTextPrimary)
                            Text("\(preview.activeCategoryCount) 个分类 · \(preview.activeTransactionCount) 笔账目")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.holoTextSecondary)
                    }
                    .holoRowHitArea()
                }
            }
        }
    }
}
