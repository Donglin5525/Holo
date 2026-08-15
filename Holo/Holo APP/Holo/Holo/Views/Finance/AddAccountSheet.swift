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

    // 信用卡账单信息（仅信用卡类型使用）
    @State private var billingDay: Int = 5
    @State private var dueDay: Int = 25
    @State private var creditLimit: String = ""

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

                    // 信用卡账单信息（仅信用卡类型）
                    if selectedType.isCreditCard {
                        creditCardInfoSection
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
                    // 加载信用卡账单信息
                    billingDay = account.billingDayInt ?? 5
                    dueDay = account.dueDayInt ?? 25
                    if let limit = account.creditLimitDecimal, limit > 0 {
                        creditLimit = String(describing: limit)
                    }
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

    // MARK: - Credit Card Info

    private var creditCardInfoSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账单信息")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 账单日
                HStack {
                    Text("账单日")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    dayStepperControl(value: $billingDay)
                }
                .padding(.vertical, HoloSpacing.sm)

                Divider()

                // 还款日
                HStack {
                    Text("还款日")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    dayStepperControl(value: $dueDay)
                }
                .padding(.vertical, HoloSpacing.sm)

                Divider()

                // 额度（选填）
                HStack {
                    Text("额度（选填）")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text("¥")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    TextField("如 30000", text: $creditLimit)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                .padding(.vertical, HoloSpacing.sm)
            }
            .padding(.horizontal, HoloSpacing.md)

            Text("账单日和还款日用于信用卡「本期账单」统计。若还款日早于账单日（如账单日 25 号、还款日 5 号），系统会自动算到次月。")
                .font(.system(size: 11))
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    /// 统一账单日/还款日的操作区宽度，避免日期文字长度变化造成按钮错位。
    private func dayStepperControl(value: Binding<Int>) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            // 周期账单为 Plus 权益：非 Plus 只读展示存量值，点击升级
            if HoloEntitlementState.shared.isPlusActive {
                Stepper("每月 \(value.wrappedValue) 号", value: value, in: 1...31)
                    .labelsHidden()
                    .frame(width: 92, height: 36)
            } else {
                Button {
                    HoloPlusActionCoordinator.shared.requirePlus(context: .billingCycle)
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .frame(width: 92, height: 36)
            }

            Text("每月 \(value.wrappedValue) 号")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .frame(width: 186, alignment: .trailing)
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let limitDecimal: Decimal? = creditLimit.isEmpty ? nil : Decimal(string: creditLimit)

        switch mode {
        case .create:
            let balance = Decimal(string: initialBalance) ?? 0
            let account = FinanceRepository.shared.addAccount(
                name: trimmedName,
                type: selectedType,
                color: selectedColor,
                initialBalance: balance,
                notes: notes.isEmpty ? nil : notes,
                billingDay: selectedType.isCreditCard ? billingDay : nil,
                dueDay: selectedType.isCreditCard ? dueDay : nil,
                creditLimit: selectedType.isCreditCard ? limitDecimal : nil
            )
            onComplete(account)
            dismiss()

        case .edit(let account):
            FinanceRepository.shared.updateAccount(
                account,
                name: trimmedName,
                color: selectedColor,
                notes: notes.isEmpty ? nil : notes,
                billingDay: selectedType.isCreditCard ? billingDay : nil,
                dueDay: selectedType.isCreditCard ? dueDay : nil,
                creditLimit: selectedType.isCreditCard ? limitDecimal : nil
            )
            onComplete(account)
            dismiss()
        }
    }
}
