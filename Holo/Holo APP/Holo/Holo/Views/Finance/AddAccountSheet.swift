//
//  AddAccountSheet.swift
//  Holo
//
//  添加/编辑账户 Sheet
//

import SwiftUI

/// 账户编辑模式
enum AccountEditMode {
    case create
    case edit(Account)
}

struct AddAccountSheet: View {

    let mode: AccountEditMode
    let onComplete: (Account) -> Void

    @Environment(\.dismiss) var dismiss

    // 表单状态
    @State private var name: String = ""
    @State private var selectedType: AccountType = .cash
    @State private var selectedColor: String = "#64748B"
    @State private var initialBalance: String = "0"
    @State private var notes: String = ""

    // UI 状态
    @State private var showError = false
    @State private var errorMessage = ""

    // 颜色预设
    private let colorPresets = [
        "#22C55E", "#07C160", "#1677FF", "#6366F1",
        "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6",
        "#14B8A6", "#F97316", "#64748B", "#0EA5E9"
    ]

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingAccount: Account? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    // 名称
                    nameSection

                    // 类型选择
                    typeSection

                    // 颜色选择
                    colorSection

                    // 初始余额（仅创建模式）
                    if !isEditMode {
                        balanceSection
                    }

                    // 备注
                    notesSection
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditMode ? "编辑账户" : "新建账户")
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
                }
            }
            .alert("保存失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let account = editingAccount {
                    name = account.name
                    selectedType = account.accountType
                    selectedColor = account.color
                    notes = account.notes ?? ""
                } else {
                    selectedColor = selectedType.defaultColor
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账户名称")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            TextField("例如：招商银行储蓄卡", text: $name)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账户类型")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        typeButton(for: type)
                    }
                }
            }
        }
    }

    private func typeButton(for type: AccountType) -> some View {
        let isSelected = selectedType == type
        let tintColor = Color(hex: type.defaultColor) ?? .holoPrimary

        return Button {
            selectedType = type
            if !isEditMode {
                selectedColor = type.defaultColor
            }
        } label: {
            VStack(spacing: HoloSpacing.xs) {
                ZStack {
                    Circle()
                        .fill(isSelected ? tintColor.opacity(0.15) : Color.holoGlassBackground)
                        .frame(width: 44, height: 44)
                    Image(systemName: type.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? tintColor : .holoTextSecondary)
                }
                Text(type.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
            }
            .padding(HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? tintColor.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? tintColor.opacity(0.3) : Color.holoBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Color

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("颜色")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.sm), count: 6), spacing: HoloSpacing.sm) {
                ForEach(colorPresets, id: \.self) { hex in
                    Button {
                        selectedColor = hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 36, height: 36)
                            if selectedColor == hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    // MARK: - Balance

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("初始余额")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Text("¥")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                TextField("0.00", text: $initialBalance)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .keyboardType(.decimalPad)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            Text("创建后可在「调整余额」中修改")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("备注")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            TextField("可选", text: $notes)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        switch mode {
        case .create:
            let balance = Decimal(string: initialBalance) ?? 0
            let account = FinanceRepository.shared.addAccount(
                name: trimmedName,
                type: selectedType,
                color: selectedColor,
                initialBalance: balance,
                notes: notes.isEmpty ? nil : notes
            )
            onComplete(account)
            dismiss()

        case .edit(let account):
            FinanceRepository.shared.updateAccount(
                account,
                name: trimmedName,
                color: selectedColor,
                notes: notes.isEmpty ? nil : notes
            )
            onComplete(account)
            dismiss()
        }
    }
}
