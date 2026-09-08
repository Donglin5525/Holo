//
//  AddProjectSheet.swift
//  Holo
//
//  新建/编辑财务项目 Sheet
//  名称（必填）+ emoji 图标 + 颜色 + 时间范围（可选）+ 预算（可选）+ 备注
//

import SwiftUI

/// 项目编辑模式
enum FinanceProjectEditMode {
    case create
    case edit(FinanceProject)
}

struct AddProjectSheet: View {

    let mode: FinanceProjectEditMode
    /// 保存成功后回调（父视图刷新列表）
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var icon: String = "📁"
    @State private var color: String = "#64748B"
    @State private var note: String = ""
    @State private var hasDateRange: Bool = false
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var budgetText: String = ""
    @State private var showIconPicker: Bool = false

    private let colorPresets = [
        "#22C55E", "#07C160", "#1677FF", "#6366F1",
        "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6",
        "#14B8A6", "#F97316", "#64748B", "#0EA5E9"
    ]

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    nameSection
                    colorSection
                    dateRangeSection
                    budgetSection
                    notesSection
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditMode ? "编辑项目" : "新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
                        .disabled(!canSave)
                        .accessibilityIdentifier("projectSheet.save")
                }
            }
            .sheet(isPresented: $showIconPicker) {
                EmojiIconPickerSheet(currentIcon: icon) { icon = $0 }
            }
            .onAppear { populateForEdit() }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 名称 + 图标

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("项目名称")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.md) {
                Button {
                    showIconPicker = true
                } label: {
                    Text(icon)
                        .font(.system(size: 26))
                        .frame(width: 52, height: 52)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.md)
                                .stroke(Color.holoBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择图标")

                TextField("例如：东京旅行、装修", text: $name)
                    .accessibilityIdentifier("projectSheet.nameField")
                    .font(.holoBody)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
    }

    // MARK: - 颜色

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("颜色")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.sm), count: 6), spacing: HoloSpacing.sm) {
                ForEach(colorPresets, id: \.self) { hex in
                    Button {
                        color = hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 36, height: 36)
                            if color == hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 时间范围（可选）

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Toggle(isOn: $hasDateRange) {
                Text("时间范围（可选）")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .tint(.holoPrimary)

            if hasDateRange {
                VStack(spacing: 0) {
                    HStack {
                        Text("开始")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        DatePicker("", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.vertical, HoloSpacing.sm)

                    Divider()

                    HStack {
                        Text("结束")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.vertical, HoloSpacing.sm)
                }
                .padding(.horizontal, HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Text("时间范围只用于展示，不影响记账——旅行结束后仍可补挂行前买的机票")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
    }

    // MARK: - 预算（可选）

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("预算（选填）")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Text("¥")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                TextField("0.00", text: $budgetText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .keyboardType(.decimalPad)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            Text("填了预算就能在项目里看花超没有；不填就纯记录")
                .font(.system(size: 11))
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    // MARK: - 备注

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("备注")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            TextField("可选", text: $note)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - 数据

    private func populateForEdit() {
        guard case .edit(let project) = mode else { return }
        name = project.name
        icon = project.icon
        color = project.color
        note = project.note ?? ""
        budgetText = project.budgetDecimal.map { String(describing: $0) } ?? ""
        if let start = project.startDate ?? project.endDate {
            hasDateRange = true
            startDate = project.startDate ?? start
            endDate = project.endDate ?? (project.startDate ?? start)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let budget: Decimal? = budgetText.isEmpty ? nil : Decimal(string: budgetText)
        let start = hasDateRange ? startDate : nil
        let end = hasDateRange ? endDate : nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            _ = try? FinanceProjectRepository.shared.create(
                name: trimmedName, icon: icon, color: color,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                startDate: start, endDate: end, budgetAmount: budget
            )
        case .edit(let project):
            try? FinanceProjectRepository.shared.update(
                project,
                name: trimmedName, icon: icon, color: color,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                startDate: start, endDate: end, budgetAmount: budget
            )
        }
        onComplete()
        dismiss()
    }
}
