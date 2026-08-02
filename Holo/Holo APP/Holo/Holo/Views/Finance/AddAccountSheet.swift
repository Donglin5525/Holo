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

    // 信用卡专属字段
    @State private var billingDay: Int = 1
    @State private var dueDay: Int = 20
    @State private var creditLimit: String = "0"

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

                    // 信用卡专属字段（仅信用卡类型显示）
                    if selectedType.isCreditCard {
                        creditCardSection
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
                    billingDay = max(Int(account.billingDay), 1)
                    dueDay = max(Int(account.dueDay), 1)
                    let limit = account.creditLimitDecimal
                    creditLimit = limit > 0 ? String(describing: limit) : "0"
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
        let tintColor = Color(hex: type.defaultColor)

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
                                .fill(Color(hex: hex))
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

    // MARK: - 信用卡专属字段

    private var creditCardSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("信用卡信息")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 账单日
                HStack {
                    Text("账单日")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Picker("", selection: $billingDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("每月 \(day) 日").tag(day)
                        }
                    }
                    .labelsHidden()
                    .tint(.holoPrimary)
                }
                .padding(HoloSpacing.md)

                Divider().padding(.leading, HoloSpacing.md)

                // 还款日
                HStack {
                    Text("还款日")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Picker("", selection: $dueDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("每月 \(day) 日").tag(day)
                        }
                    }
                    .labelsHidden()
                    .tint(.holoPrimary)
                }
                .padding(HoloSpacing.md)

                Divider().padding(.leading, HoloSpacing.md)

                // 信用额度
                HStack {
                    Text("信用额度")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    TextField("0", text: $creditLimit)
                        .font(.holoBody)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .foregroundColor(.holoTextPrimary)
                    Text("元")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let limit = Decimal(string: creditLimit) ?? 0

        switch mode {
        case .create:
            let balance = Decimal(string: initialBalance) ?? 0
            let account = FinanceRepository.shared.addAccount(
                name: trimmedName,
                type: selectedType,
                color: selectedColor,
                initialBalance: balance,
                notes: notes.isEmpty ? nil : notes,
                billingDay: selectedType.isCreditCard ? Int16(billingDay) : 0,
                dueDay: selectedType.isCreditCard ? Int16(dueDay) : 0,
                creditLimit: selectedType.isCreditCard ? limit : 0
            )
            CreditCardReminderService.shared.scheduleReminders(for: account)
            onComplete(account)
            dismiss()

        case .edit(let account):
            FinanceRepository.shared.updateAccount(
                account,
                name: trimmedName,
                color: selectedColor,
                notes: notes.isEmpty ? nil : notes,
                type: selectedType,
                billingDay: selectedType.isCreditCard ? Int16(billingDay) : 0,
                dueDay: selectedType.isCreditCard ? Int16(dueDay) : 0,
                creditLimit: selectedType.isCreditCard ? limit : 0
            )
            CreditCardReminderService.shared.scheduleReminders(for: account)
            onComplete(account)
            dismiss()
        }
    }
}
