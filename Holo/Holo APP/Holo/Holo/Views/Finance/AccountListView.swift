//
//  AccountListView.swift
//  Holo
//
//  账户总览页 - 展示净资产、按类型分组的账户列表
//

import SwiftUI

struct AccountListView: View {

    @State private var accounts: [Account] = []
    @State private var showAddAccount = false
    @State private var netWorthData: (assets: Decimal, liabilities: Decimal, netWorth: Decimal) = (0, 0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xl) {
                // 净资产总览卡片
                netWorthCard

                // 按类型分组的账户列表
                accountListSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle("账户管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddAccount = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet(mode: .create) { _ in
                loadData()
            }
        }
        .onAppear {
            loadData()
        }
    }

    // MARK: - Net Worth Card

    private var netWorthCard: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("净资产")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Text(formatAmount(netWorthData.netWorth))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(netWorthData.netWorth >= 0 ? .holoTextPrimary : .holoError)

            HStack(spacing: HoloSpacing.xl) {
                VStack(spacing: HoloSpacing.xs) {
                    Text("总资产")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(netWorthData.assets))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoSuccess)
                }

                Spacer()

                VStack(spacing: HoloSpacing.xs) {
                    Text("总负债")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(netWorthData.liabilities))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoError)
                }
            }
        }
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Account List

    private var accountListSection: some View {
        VStack(spacing: HoloSpacing.md) {
            // 按类型分组
            ForEach(groupedAccounts.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { accountType in
                if let typeAccounts = groupedAccounts[accountType], !typeAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text(accountType.displayName)
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                            .padding(.leading, HoloSpacing.xs)

                        VStack(spacing: HoloSpacing.xs) {
                            ForEach(typeAccounts, id: \.objectID) { account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    accountRow(account)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(account.swiftUIColor.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: account.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(account.swiftUIColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HoloSpacing.xs) {
                    Text(account.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    if account.isDefault {
                        Text("默认")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if account.isArchived {
                        Text("已归档")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.holoGlassBackground)
                            .clipShape(Capsule())
                    }
                }

                Text(account.accountType.displayName)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            let balance = FinanceRepository.shared.getAccountBalance(account)
            Text(formatAmount(balance))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(balance >= 0 ? .holoTextPrimary : .holoError)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Helpers

    private var groupedAccounts: [AccountType: [Account]] {
        var groups: [AccountType: [Account]] = [:]
        for account in accounts {
            let type = account.accountType
            groups[type, default: []].append(account)
        }
        return groups
    }

    private func loadData() {
        accounts = FinanceRepository.shared.getAccounts(includeArchived: true)
        netWorthData = FinanceRepository.shared.getTotalNetWorth()
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}
