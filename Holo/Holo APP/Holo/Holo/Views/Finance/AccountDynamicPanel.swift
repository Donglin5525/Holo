//
//  AccountDynamicPanel.swift
//  Holo
//
//  账户卡堆下方的动态信息区：随当前选中卡联动——
//  信用卡显示本期账单 / 还款倒计时 / 额度明细，普通账户显示本月收支与近期交易。
//  把账户详情页最高频的三成信息前置，多数场景不必进详情。
//

import SwiftUI

// MARK: - 动态区数据（父视图统一取数）

struct AccountDynamicData {
    let monthly: (income: Decimal, expense: Decimal, net: Decimal)
    let recents: [Transaction]
    /// 信用卡本期账单（账单周期内支出合计）
    var billAmount: Decimal?
    /// 距还款日天数（负数 = 已逾期）
    var daysToDue: Int?

    static func load(for account: Account) -> AccountDynamicData {
        let monthly = FinanceRepository.shared.getAccountMonthlySummary(accountId: account.id, month: Date())

        // 近期交易取本账单周期内的最近 3 笔（口径与月度收支一致）
        let cycle = FinancePeriodSettings.shared.currentCycleRange(reference: Date())
        let recents = Array(
            FinanceRepository.shared.getAccountTransactions(accountId: account.id, from: cycle.start)
                .prefix(3)
        )

        var bill: Decimal?
        var daysToDue: Int?
        if account.accountType.isCreditCard, let billingDay = account.billingDayInt {
            let range = BillingCycleCalculator.currentCycleRange(startDay: billingDay, reference: Date())
            bill = FinanceRepository.shared.getAccountSummary(accountId: account.id, from: range.start, to: range.end).expense
            if let dueDay = account.dueDayInt {
                let dueDate = BillingCycleCalculator.dueDate(billingDay: billingDay, dueDay: dueDay, cycleStart: range.start)
                let calendar = Calendar.current
                daysToDue = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: Date()),
                    to: calendar.startOfDay(for: dueDate)
                ).day ?? 0
            }
        }

        return AccountDynamicData(monthly: monthly, recents: recents, billAmount: bill, daysToDue: daysToDue)
    }
}

// MARK: - 面板

struct AccountDynamicPanel: View {
    let account: Account
    let data: AccountDynamicData
    var onOpenDetail: (Account) -> Void

    private var accent: Color {
        AccountCardPalette.palette(for: account).accent
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部账户色渐变条 + 色点
            LinearGradient(colors: [accent, accent.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 3)

            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent, radius: 4)
                Text("\(account.name) · 动态")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                Text("\(account.accountType.displayName) · \(account.accountType.englishLabel)")
                    .font(.system(size: 10.5))
                    .tracking(0.8)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if account.accountType.isCreditCard {
                creditGrid
            } else {
                balanceGrid
            }

            ForEach(data.recents) { tx in
                TransactionRowView(transaction: tx, showsDate: true) {
                    onOpenDetail(account)
                }
            }

            Button {
                onOpenDetail(account)
            } label: {
                Text("查看全部交易 ›")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoPrimaryDark)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 11)
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }

    // MARK: 三格统计

    private var creditGrid: some View {
        grid(
            cell(title: "本期账单 BILL", value: "¥\(AccountCardFormat.amount(data.billAmount ?? 0))", color: Color(hex: "#B45309")),
            cell(title: "距还款日 DUE", value: dueText, color: dueColor),
            cell(title: "本月净支出 NET", value: "¥\(AccountCardFormat.amount(data.monthly.expense))", color: .holoTextPrimary)
        )
    }

    private var balanceGrid: some View {
        grid(
            cell(title: "本月收入 IN", value: "+¥\(AccountCardFormat.amount(data.monthly.income))", color: .holoSuccess),
            cell(title: "本月支出 OUT", value: "¥\(AccountCardFormat.amount(data.monthly.expense))", color: .holoTextPrimary),
            cell(title: "净收支 NET", value: "\(data.monthly.net >= 0 ? "+" : "")¥\(AccountCardFormat.amount(data.monthly.net))", color: data.monthly.net >= 0 ? .holoSuccess : .holoError)
        )
    }

    private func cell(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.6)
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    /// 三格统计行（格间细分隔线）
    private func grid(_ c1: some View, _ c2: some View, _ c3: some View) -> some View {
        HStack(spacing: 0) {
            c1.overlay(alignment: .trailing) { separator }
            c2.overlay(alignment: .trailing) { separator }
            c3
        }
        .overlay(alignment: .top) { Color.holoDivider.opacity(0.5).frame(height: 0.5).padding(.horizontal, 14) }
    }

    private var separator: some View {
        Color.holoDivider.opacity(0.5).frame(width: 0.5, height: 26)
    }

    private var dueText: String {
        switch data.daysToDue {
        case .some(let d) where d > 0: return "\(d) 天"
        case .some(0): return "今天"
        case .some(let d): return "逾期 \(-d) 天"
        case .none: return "未设置"
        }
    }

    private var dueColor: Color {
        // 已逾期或 3 天内到期用警示色（口径与账户详情页一致）
        if let d = data.daysToDue, d <= 3 { return .holoError }
        return .holoTextPrimary
    }
}
