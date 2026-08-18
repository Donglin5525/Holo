//
//  KanbanBudgetSection.swift
//  Holo
//
//  今日看板 — 月度预算摘要卡片（支持按账户切换，默认全部账户汇总）
//

import SwiftUI

struct KanbanBudgetSection: View {

    @State private var cardData: BudgetCardData?
    @State private var accounts: [Account] = []
    @State private var selectedAccountHasBudget = true
    @State private var todayExpense: Decimal?

    /// 选中的账户 ID，空字符串表示"全部账户"（跨账户汇总）
    @AppStorage("kanbanBudgetSelectedAccountId") private var selectedAccountId: String = ""

    var body: some View {
        if cardData != nil || !selectedAccountHasBudget {
            section
                .onAppear { loadBudget() }
        } else {
            EmptyView()
                .onAppear { loadBudget() }
        }
    }

    private var section: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 12) {
                if let data = cardData {
                    budgetOverview(data: data)
                    budgetBar(data: data)
                    budgetDetails(data: data)
                } else {
                    Text("该账户未设置月度预算")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(16)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Label("月度预算", systemImage: "wallet.pass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
            if accounts.count > 1 {
                accountSwitcher
            }
        }
        .padding(.horizontal, 4)
    }

    private var accountSwitcher: some View {
        Menu {
            Button {
                selectAccount(nil)
            } label: {
                Label("全部账户", systemImage: selectedAccountId.isEmpty ? "checkmark" : "")
            }
            ForEach(accounts, id: \.id) { account in
                Button {
                    selectAccount(account)
                } label: {
                    Label(account.name, systemImage: selectedAccountId == account.id.uuidString ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedAccountName)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    private var selectedAccountName: String {
        if let selected = accounts.first(where: { $0.id.uuidString == selectedAccountId }) {
            return selected.name
        }
        return "全部账户"
    }

    private func budgetOverview(data: BudgetCardData) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.isOverBudget ? "已超支" : "本月剩余")
                    .font(.holoLabel)
                    .foregroundColor(data.isOverBudget ? .holoError : .holoTextSecondary)
                HStack(spacing: 4) {
                    if data.isOverBudget {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.holoError)
                    }
                    Text(data.isOverBudget ? data.overAmountFormatted : data.remainingFormatted)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(data.isOverBudget ? .holoError : .holoTextPrimary)
                    Text("/ \(data.budgetFormatted)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                if let note = data.carryoverNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
            Spacer()
        }
    }

    private func budgetBar(data: BudgetCardData) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider)
                        .frame(height: 6)

                    Capsule()
                        .fill(budgetBarColor(progress: data.progress))
                        .frame(width: max(geo.size.width * min(data.progress, 1.0), 0), height: 6)
                        .overlay {
                            if data.isOverBudget {
                                OverBudgetStripeOverlay()
                                    .clipShape(Capsule())
                            }
                        }
                        .animation(.spring(response: 0.5), value: data.progress)
                }
            }
            .frame(height: 6)

            if data.isOverBudget {
                Text("超支 \(data.overPercent)%")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoError)
            }
        }
    }

    private func budgetDetails(data: BudgetCardData) -> some View {
        HStack(spacing: 10) {
            budgetDetailItem(
                label: "今日支出",
                value: todayExpenseFormatted,
                color: .holoTextPrimary
            )
            budgetDetailItem(
                label: "日均可用",
                value: data.isOverBudget ? "¥0" : data.dailyBudgetFormatted,
                color: .holoInfo
            )
            budgetDetailItem(
                label: "剩余天数",
                value: "\(data.remainingDays)天",
                color: .holoSuccess
            )
        }
    }

    private func budgetDetailItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func budgetBarColor(progress: Double) -> Color {
        if progress >= 1.0 { return .holoError }
        if progress >= 0.8 { return .holoPrimary }
        if progress >= 0.6 { return .holoPrimary }
        return .holoSuccess
    }

    private func selectAccount(_ account: Account?) {
        selectedAccountId = account?.id.uuidString ?? ""
        loadBudget()
    }

    private func loadBudget() {
        Task { @MainActor in
            accounts = FinanceRepository.shared.getAccounts(includeArchived: false)

            // 选中的账户可能已被删除，回退到"全部账户"
            let selected = accounts.first(where: { $0.id.uuidString == selectedAccountId })

            if let selected {
                let status = BudgetRepository.shared.computeTotalBudgetStatus(
                    forAccount: selected.id,
                    period: .month
                )
                selectedAccountHasBudget = status != nil
                cardData = status.map { BudgetCardData(status: $0) }
            } else {
                selectedAccountHasBudget = true
                cardData = BudgetRepository.shared
                    .computeGlobalTotalBudgetStatus(period: .month)
                    .map { BudgetCardData(summary: $0) }
            }

            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
            do {
                let transactions = try await FinanceRepository.shared.getTransactions(from: start, to: end)
                todayExpense = transactions
                    .filter { transaction in
                        transaction.transactionType == .expense
                            && (selected == nil || transaction.account?.id == selected?.id)
                    }
                    .reduce(Decimal.zero) { $0 + ($1.amount as Decimal) }
            } catch {
                todayExpense = nil
            }
        }
    }

    private var todayExpenseFormatted: String {
        guard let todayExpense else { return "加载中" }
        return NumberFormatter.currency.string(from: NSDecimalNumber(decimal: todayExpense)) ?? "¥0"
    }
}

/// 预算卡片视图数据（统一"全部账户汇总"与"单账户"两种来源）
private struct BudgetCardData {
    /// 有效额度（严格模式 = 原始额度 − 上期超支结转），作为展示与超支判定的分母
    let budgetAmount: Decimal
    let originalAmount: Decimal
    let carryoverDeduction: Decimal
    let spentAmount: Decimal
    let remainingAmount: Decimal
    let progress: Double
    let remainingDays: Int

    init(summary: GlobalBudgetSummary) {
        budgetAmount = summary.totalBudgetAmount
        originalAmount = summary.totalOriginalAmount
        carryoverDeduction = summary.totalCarryoverDeduction
        spentAmount = summary.totalSpentAmount
        remainingAmount = summary.totalRemainingAmount
        progress = summary.progress
        remainingDays = summary.remainingDays
    }

    init(status: BudgetStatus) {
        budgetAmount = status.effectiveAmount
        originalAmount = status.budgetAmount
        carryoverDeduction = status.carryoverDeduction
        spentAmount = status.spentAmount
        remainingAmount = status.remainingAmount
        progress = status.progress
        remainingDays = status.remainingDays
    }

    var isOverBudget: Bool { progress >= 1.0 }

    var overAmount: Decimal { max(0, spentAmount - budgetAmount) }

    /// 严格预算模式：结转扣减说明（nil = 无结转）
    var carryoverNote: String? {
        guard carryoverDeduction > 0 else { return nil }
        let deduction = Self.currencyFormatter.string(from: NSDecimalNumber(decimal: carryoverDeduction)) ?? "¥0"
        let original = Self.currencyFormatter.string(from: NSDecimalNumber(decimal: originalAmount)) ?? "¥0"
        return "上月超支结转 −\(deduction) · 原额度 \(original)"
    }

    /// 超支百分比（向上取整，保证只要超支就至少显示 1%），如 progress = 1.12 时为 12
    var overPercent: Int {
        guard isOverBudget else { return 0 }
        return max(1, Int(ceil((progress - 1.0) * 100)))
    }

    var budgetFormatted: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: budgetAmount)) ?? "¥0"
    }

    var remainingFormatted: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: remainingAmount)) ?? "¥0"
    }

    var overAmountFormatted: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: overAmount)) ?? "¥0"
    }

    var dailyBudgetFormatted: String {
        guard remainingDays > 0 else { return "¥0" }
        let daily = remainingAmount / Decimal(remainingDays)
        return Self.currencyFormatter.string(from: NSDecimalNumber(decimal: daily)) ?? "¥0"
    }

    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}
