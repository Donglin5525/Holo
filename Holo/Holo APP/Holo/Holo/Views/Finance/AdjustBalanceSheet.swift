//
//  AdjustBalanceSheet.swift
//  Holo
//
//  余额调整 Sheet - 对比当前余额与实际余额，创建调整交易
//

import SwiftUI

struct AdjustBalanceSheet: View {

    let account: Account
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss

    @State private var currentBalance: Decimal = 0
    @State private var newBalanceString: String = ""
    @State private var note: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var newBalance: Decimal {
        Decimal(string: newBalanceString) ?? 0
    }

    private var difference: Decimal {
        newBalance - currentBalance
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.xl) {
                // 当前余额
                VStack(spacing: HoloSpacing.xs) {
                    Text("当前余额")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(currentBalance))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                }
                .padding(HoloSpacing.lg)
                .frame(maxWidth: .infinity)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                // 实际余额输入
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("实际余额")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    HStack(spacing: HoloSpacing.sm) {
                        Text("¥")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.holoTextPrimary)
                        TextField("0.00", text: $newBalanceString)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .keyboardType(.decimalPad)
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }

                // 差异显示
                if !newBalanceString.isEmpty {
                    VStack(spacing: HoloSpacing.xs) {
                        Text("差额")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: HoloSpacing.xs) {
                            Image(systemName: difference > 0 ? "arrow.up.circle.fill" : difference < 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                                .foregroundColor(difference > 0 ? .holoSuccess : difference < 0 ? .holoError : .holoPrimary)

                            Text(difference >= 0 ? "+\(formatAmount(difference))" : formatAmount(difference))
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(difference >= 0 ? .holoSuccess : .holoError)
                        }

                        Text(difference > 0 ? "将记录为一笔收入" : difference < 0 ? "将记录为一笔支出" : "余额无变化")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(HoloSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }

                // 备注
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("备注（可选）")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    TextField("例如：存入年终奖", text: $note)
                        .font(.holoBody)
                        .padding(HoloSpacing.md)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("调整余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认调整") { adjust() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(difference != 0 ? .holoPrimary : .holoTextSecondary)
                        .disabled(difference == 0)
                }
            }
            .alert("调整失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                currentBalance = FinanceRepository.shared.getAccountBalance(account)
                newBalanceString = String(describing: currentBalance)
            }
        }
    }

    private func adjust() {
        do {
            _ = try FinanceRepository.shared.adjustBalance(
                account: account,
                newBalance: newBalance,
                note: note.isEmpty ? nil : note
            )
            HapticManager.success()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: abs(amount))) ?? "¥0.00"
    }
}
