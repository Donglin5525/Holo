//
//  BudgetSettingsSheet.swift
//  Holo
//
//  预算设置 Sheet - 新建/编辑账户预算
//

import SwiftUI

struct BudgetSettingsSheet: View {

    let account: Account
    let existingBudget: Budget?
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss

    @State private var amountString: String = ""
    @State private var selectedPeriod: BudgetPeriod = .month
    @State private var startDate: Date = Date()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirm = false

    private var isEditMode: Bool { existingBudget != nil }

    private var budgetAmount: Decimal {
        Decimal(string: amountString) ?? 0
    }

    private var isValid: Bool {
        budgetAmount > 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.xl) {
                // 预算金额输入
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("预算金额")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    HStack(spacing: HoloSpacing.sm) {
                        Text("¥")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.holoTextPrimary)
                        TextField("0.00", text: $amountString)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .keyboardType(.decimalPad)
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }

                // 预算周期选择
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("预算周期")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    HStack(spacing: HoloSpacing.sm) {
                        ForEach(BudgetPeriod.allCases) { period in
                            HoloFilterChip(
                                title: period.displayName,
                                isSelected: selectedPeriod == period,
                                action: {
                                    if !isEditMode {
                                        selectedPeriod = period
                                    }
                                }
                            )
                        }
                    }
                }

                // 起始日期
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("起始日期")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    DatePicker(
                        "",
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .padding(HoloSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }

                // 编辑模式下显示删除按钮
                if isEditMode {
                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除预算")
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoError)
                        .frame(maxWidth: .infinity)
                        .padding(HoloSpacing.md)
                        .background(Color.holoError.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }
                }

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle(isEditMode ? "预算设置" : "新建预算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditMode ? "保存" : "创建") {
                        saveBudget()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isValid ? .holoPrimary : .holoTextSecondary)
                    .disabled(!isValid)
                }
            }
            .alert("操作失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .alert("确认删除", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteBudget()
                }
            } message: {
                Text("确定要删除该预算吗？删除后预算追踪将停止。")
            }
            .onAppear {
                if let budget = existingBudget {
                    amountString = String(describing: budget.amount.decimalValue)
                    selectedPeriod = budget.budgetPeriod
                    startDate = budget.startDate
                } else {
                    // 新建模式：默认起始日期为下月1号
                    let cal = Calendar.current
                    let now = Date()
                    var components = cal.dateComponents([.year, .month], from: now)
                    components.month! += 1
                    components.day = 1
                    startDate = cal.date(from: components) ?? now
                }
            }
        }
    }

    // MARK: - Actions

    private func saveBudget() {
        do {
            if let budget = existingBudget {
                try BudgetRepository.shared.updateBudget(
                    budget,
                    amount: budgetAmount,
                    startDate: startDate
                )
            } else {
                _ = try BudgetRepository.shared.addBudget(
                    accountId: account.id,
                    amount: budgetAmount,
                    period: selectedPeriod,
                    startDate: startDate
                )
            }
            HapticManager.success()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteBudget() {
        guard let budget = existingBudget else { return }
        do {
            try BudgetRepository.shared.deleteBudget(budget)
            HapticManager.success()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
