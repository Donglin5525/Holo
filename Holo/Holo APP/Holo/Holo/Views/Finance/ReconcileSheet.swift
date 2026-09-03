//
//  ReconcileSheet.swift
//  Holo
//
//  余额对账 Sheet —— 拿银行/App 里的真实余额核对账本余额：
//  差额=0 确认对平写锚点；差额≠0 可生成对账调整流水、改期初余额、或去修改记错的那笔账。
//

import SwiftUI

struct ReconcileSheet: View {

    let account: Account
    /// 差额来自更早历史时，引导去编辑账户改期初余额
    let onEditInitialBalance: (Account) -> Void
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss

    @State private var currentBalance: Decimal = 0
    @State private var actualBalanceString: String = ""
    @State private var note: String = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var reconciled = false

    @FocusState private var isAmountFocused: Bool
    @FocusState private var isNoteFocused: Bool

    private var actualBalance: Decimal? {
        // 空值不算 0：必须显式输入才能确认，防止误把「没填」当「对平」
        actualBalanceString.isEmpty ? nil : Decimal(string: actualBalanceString)
    }

    private var difference: Decimal? {
        guard let actual = actualBalance else { return nil }
        return actual - currentBalance
    }

    /// 已输入且差额为 0 → 本来就对平，动作是「确认并写锚点」
    private var isFlat: Bool { difference == 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HoloSpacing.xl) {
                    balanceCard
                    inputCard

                    if reconciled {
                        doneCard
                    } else if let difference, difference != 0 {
                        differenceCard(difference)
                        actionSection
                    } else if isFlat {
                        flatCard
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        isAmountFocused = false
                        isNoteFocused = false
                    }
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("对账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !reconciled {
                        Button(isFlat ? "确认对平" : "补齐差额") { reconcile() }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(difference != nil ? .holoPrimary : .holoTextSecondary)
                            .disabled(difference == nil)
                    }
                }
            }
            .alert("对账失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                currentBalance = FinanceRepository.shared.getAccountBalance(account)
            }
        }
    }

    // MARK: - 账本余额

    private var balanceCard: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text("账本余额")
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
    }

    // MARK: - 实际余额输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("银行 App 里的实际余额")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Text("¥")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                TextField("0.00", text: $actualBalanceString)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            // 信用卡/欠款账户：银行 App 展示的「欠款」是正数，这里要输负数，必须提前讲清
            if account.accountType.isCreditCard || currentBalance < 0 {
                let outstanding = abs(min(currentBalance, 0))
                Text(currentBalance < 0
                     ? "当前为欠款状态（欠 ¥\(outstanding)）。银行 App 显示的「欠款 ¥\(outstanding)」在这里请输入 \(-outstanding)（负数）"
                     : "信用卡如处于欠款状态，请输入负数（如 -3200）")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            if !reconciled, difference == nil || difference != 0 {
                TextField("备注（可选，如：漏记一笔外卖）", text: $note)
                    .font(.holoBody)
                    .focused($isNoteFocused)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
    }

    // MARK: - 差额说明

    private func differenceCard(_ difference: Decimal) -> some View {
        let bookHigher = difference < 0
        return VStack(spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: bookHigher ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundColor(bookHigher ? .holoError : .holoSuccess)
                Text("账本比实际\(bookHigher ? "多记了" : "少了") \(formatAmount(abs(difference)))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }
            Text("用调整流水补齐后，这笔差额不影响收支统计")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var flatCard: some View {
        VStack(spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.holoSuccess)
                Text("账本与实际一致")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }
            Text("确认后记录对账时间，余额可信度以此为准")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var doneCard: some View {
        VStack(spacing: HoloSpacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundColor(.holoSuccess)
            Text("已对平")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Text("余额已与实际一致")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 其他出路

    private var actionSection: some View {
        VStack(spacing: HoloSpacing.md) {
            Button {
                onEditInitialBalance(account)
                dismiss()
            } label: {
                Label("差额来自更早的历史？修改期初余额", systemImage: "calendar.badge.plus")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                // 知道是哪笔记错 → 直接去改，改完回来再对；未对平不写锚点
                dismiss()
            } label: {
                Label("我知道是哪笔记错了，去修改那笔账", systemImage: "pencil.line")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - 动作

    private func reconcile() {
        guard let actual = actualBalance else { return }
        // 用实时余额判断而非 onAppear 快照：sheet 开着期间可能有 CloudKit 同步进来的新账，
        // 快照过期时按快照差额动作会错（同步账恰好抹平差额时还会误报「余额无变化」）
        let liveBalance = FinanceRepository.shared.getAccountBalance(account)
        do {
            if actual != liveBalance {
                _ = try FinanceRepository.shared.adjustBalance(
                    account: account,
                    newBalance: actual,
                    note: note.isEmpty ? nil : note
                )
            }
            // 对平（本来就平，或调整流水已补齐）→ 写锚点
            FinanceRepository.shared.markReconciled(
                account,
                balance: FinanceRepository.shared.getAccountBalance(account)
            )
            HapticManager.success()
            reconciled = true
            onComplete()
            // 停留展示「已对平」态，让用户看到结果再手动关闭
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
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
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}
