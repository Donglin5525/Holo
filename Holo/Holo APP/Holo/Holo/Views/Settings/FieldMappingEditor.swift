//
//  FieldMappingEditor.swift
//  Holo
//
//  字段映射编辑弹窗 — 用户手动修正 CSV 列与 HOLO 字段的对应关系
//

import SwiftUI

struct FieldMappingEditor: View {

    @Environment(\.dismiss) var dismiss
    @State private var editing: FieldMapping

    let headers: [String]
    let currentMapping: FieldMapping
    let onSave: (FieldMapping) -> Void
    let onCancel: () -> Void

    init(
        headers: [String],
        currentMapping: FieldMapping,
        onSave: @escaping (FieldMapping) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.headers = headers
        self.currentMapping = currentMapping
        self.onSave = onSave
        self.onCancel = onCancel
        _editing = State(wrappedValue: currentMapping)
    }

    /// 金额是否已选择
    private var isAmountSelected: Bool { editing.amountIndex != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部标题栏
                headerBar

                Divider()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.md) {
                        fieldPicker(label: "日期", icon: "calendar", selectedIndex: $editing.dateIndex)
                        fieldPicker(label: "类型", icon: "arrow.left.arrow.right", selectedIndex: $editing.typeIndex)
                        fieldPicker(label: "金额（必选）", icon: "yensign", selectedIndex: $editing.amountIndex, required: true)
                        fieldPicker(label: "一级分类", icon: "folder", selectedIndex: $editing.primaryCategoryIndex)
                        fieldPicker(label: "二级分类", icon: "tag", selectedIndex: $editing.subCategoryIndex)
                        fieldPicker(label: "账户", icon: "wallet.pass", selectedIndex: $editing.accountIndex)
                        fieldPicker(label: "备注", icon: "note.text", selectedIndex: $editing.noteIndex)
                    }
                    .padding(HoloSpacing.md)
                }

                // 底部按钮
                Divider()
                bottomBar
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 顶部标题栏

    private var headerBar: some View {
        HStack {
            Button { onCancel() } label: {
                Text("取消")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Text("编辑字段映射")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Button { onSave(editing) } label: {
                Text("保存")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isAmountSelected ? .holoPrimary : .holoTextSecondary.opacity(0.3))
            }
            .disabled(!isAmountSelected)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
    }

    // MARK: - 字段选择器

    private func fieldPicker(
        label: String,
        icon: String,
        selectedIndex: Binding<Int?>,
        required: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(required && !isAmountSelected ? .red : .holoPrimary)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                if required && !isAmountSelected {
                    Text("(必选)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            Picker(selection: selectedIndex, label: Text(label)) {
                Text("不映射").tag(nil as Int?)
                ForEach(headers.indices, id: \.self) { i in
                    Text(headers[i]).tag(i as Int?)
                }
            }
            .pickerStyle(.menu)
            .tint(.holoPrimary)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 底部按钮

    private var bottomBar: some View {
        HStack(spacing: HoloSpacing.md) {
            Button { onCancel() } label: {
                Text("取消")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .stroke(Color.holoDivider, lineWidth: 1)
                    )
            }

            Button { onSave(editing) } label: {
                Text("重新解析")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(isAmountSelected ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .disabled(!isAmountSelected)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
    }
}
