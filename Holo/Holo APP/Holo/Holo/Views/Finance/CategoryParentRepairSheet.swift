import SwiftUI

/// 使用纯值预览核对影响；只有明确选择一级并确认后才写回。
struct CategoryParentRepairSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: CategoryParentRepairPreview
    let targets: [CategoryParentRepairTarget]
    let onRepair: (CategoryParentRepairTarget) async throws -> Void
    @State private var selectedID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("这些二级分类的原一级分类已不可用。请选择正确的一级归属，恢复完整分类路径。")
                    Text("恢复后会更新一级分类的统计归属。账目金额、日期、账户和备注保持原样，同名分类会保留。")
                        .foregroundStyle(.secondary)
                }
                Section("涉及分类") {
                    ForEach(preview.items) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            if item.isDeleted { Text("最近删除").foregroundStyle(.secondary) }
                        }
                    }
                    LabeledContent("有效账目", value: "\(preview.activeTransactionCount) 笔")
                    if preview.deletedTransactionCount > 0 {
                        LabeledContent("最近删除账目", value: "\(preview.deletedTransactionCount) 笔")
                    }
                    Text("最近删除中的分类与账目会保留删除状态。")
                        .font(.holoCaption)
                        .foregroundStyle(.secondary)
                }
                Section("恢复到一级分类") {
                    Picker("一级分类", selection: $selectedID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(targets) { target in
                            Text(target.name).tag(Optional(target.id))
                        }
                    }
                    if targets.isEmpty { Text("请先新建一个一级分类。") }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .disabled(isSaving)
            .navigationTitle("恢复分类归属")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "恢复归属") {
                        guard let target = targets.first(where: { $0.id == selectedID }) else { return }
                        isSaving = true
                        Task {
                            do {
                                try await onRepair(target)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || selectedID == nil)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}
