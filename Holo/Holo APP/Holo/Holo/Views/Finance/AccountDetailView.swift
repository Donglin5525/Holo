//
//  AccountDetailView.swift
//  Holo
//
//  账户详情页 - 账户信息、月度统计、交易历史
//

import SwiftUI

struct AccountDetailView: View {

    let account: Account

    @State private var balance: Decimal = 0
    @State private var monthlySummary: (income: Decimal, expense: Decimal, net: Decimal) = (0, 0, 0)
    @State private var transactions: [Transaction] = []
    @State private var showEditSheet = false
    @State private var showAdjustBalance = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xl) {
                // 账户信息头部
                accountHeader

                // 月度统计
                monthlyStatsCard

                // 交易历史
                transactionListSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button {
                        showAdjustBalance = true
                    } label: {
                        Label("调整余额", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if account.isDefault {
                        Button {} label: {
                            Label("设为默认（当前默认）", systemImage: "star.fill")
                        }
                        .disabled(true)
                    } else {
                        Button {
                            FinanceRepository.shared.setDefaultAccount(account)
                            loadData()
                        } label: {
                            Label("设为默认", systemImage: "star")
                        }
                    }

                    Divider()

                    if !account.isArchived {
                        Button(role: .destructive) {
                            do {
                                try FinanceRepository.shared.archiveAccount(account)
                                loadData()
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        } label: {
                            Label("归档", systemImage: "archivebox")
                        }
                    } else {
                        Button {
                            FinanceRepository.shared.unarchiveAccount(account)
                            loadData()
                        } label: {
                            Label("取消归档", systemImage: "archivebox.fill")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddAccountSheet(mode: .edit(account)) { _ in
                loadData()
            }
        }
        .sheet(isPresented: $showAdjustBalance) {
            AdjustBalanceSheet(account: account) {
                loadData()
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do {
                    try FinanceRepository.shared.deleteAccount(account)
                    // 返回上一页
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        } message: {
            Text("确定要删除账户「\(account.name)」吗？")
        }
        .alert("操作失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onAppear {
            loadData()
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        VStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(account.swiftUIColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: account.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(account.swiftUIColor)
            }

            Text(account.name)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            Text(formatAmount(balance))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(balance >= 0 ? .holoTextPrimary : .holoError)

            HStack(spacing: HoloSpacing.sm) {
                Text(account.accountType.displayName)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.holoGlassBackground)
                    .clipShape(Capsule())

                if account.isDefault {
                    Text("默认账户")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Monthly Stats

    private var monthlyStatsCard: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("本月统计")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                VStack(spacing: HoloSpacing.xs) {
                    Text("收入")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.income))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoSuccess)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 36)

                VStack(spacing: HoloSpacing.xs) {
                    Text("支出")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.expense))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoError)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 36)

                VStack(spacing: HoloSpacing.xs) {
                    Text("净变动")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.net))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(monthlySummary.net >= 0 ? .holoSuccess : .holoError)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Transaction List

    private var transactionListSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("交易记录")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            if transactions.isEmpty {
                VStack(spacing: HoloSpacing.md) {
                    Image(systemName: "receipt")
                        .font(.system(size: 32))
                        .foregroundColor(.holoTextSecondary)
                    Text("暂无交易记录")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(HoloSpacing.xl)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            } else {
                // 按日期分组
                let grouped = groupByDate(transactions)
                ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                    if let dayTransactions = grouped[date] {
                        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                            Text(formatDate(date))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .padding(.leading, HoloSpacing.sm)

                            ForEach(dayTransactions, id: \.objectID) { tx in
                                transactionRow(tx)
                            }
                        }
                    }
                }
            }
        }
    }

    private func transactionRow(_ tx: Transaction) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(tx.category.swiftUIColor.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: tx.category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tx.category.swiftUIColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.note ?? tx.category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                if tx.category.isSystem {
                    Text("[余额调整]")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            let amount = tx.amount.decimalValue
            Text(tx.transactionType == .income ? "+\(formatAmount(amount))" : "-\(formatAmount(amount))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(tx.transactionType == .income ? .holoSuccess : .holoError)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func loadData() {
        balance = FinanceRepository.shared.getAccountBalance(account)
        monthlySummary = FinanceRepository.shared.getAccountMonthlySummary(
            accountId: account.id,
            month: Date()
        )
        transactions = FinanceRepository.shared.getAccountTransactions(accountId: account.id)
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: abs(amount))) ?? "¥0.00"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    private func groupByDate(_ transactions: [Transaction]) -> [Date: [Transaction]] {
        var groups: [Date: [Transaction]] = [:]
        for tx in transactions {
            let key = Calendar.current.startOfDay(for: tx.date)
            groups[key, default: []].append(tx)
        }
        return groups
    }
}
