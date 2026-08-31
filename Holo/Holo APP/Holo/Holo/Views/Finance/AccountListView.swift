//
//  AccountListView.swift
//  Holo
//
//  账户总览页 - 财务模块底部第 1 个 Tab
//  净资产卡 + 全部账户平铺列表（点行进详情、长按弹出管理菜单）
//  【1.0.1 改版】收起卡堆拟物形式，回归信息密度优先的列表骨架：
//  一屏看全所有账户，点哪进哪，无翻卡、无置顶、无屏中空白。
//

import SwiftUI

extension Account: Identifiable {}

// MARK: - 列表行数据

/// 账户列表一行需要的数据（余额在父视图统一取数，避免行内反复查询）
struct AccountRowItem: Identifiable {
    let account: Account
    let balance: Decimal

    var id: UUID { account.id }

    /// 信用卡余额为负（欠款），行内语义「已用额度」取其绝对值
    var outstanding: Decimal? {
        guard account.accountType.isCreditCard, balance < 0 else { return nil }
        return -balance
    }

    /// 普通账户余额为负 = 负债状态，与净资产卡「总负债」同一口径
    var isDebt: Bool {
        !account.accountType.isCreditCard && balance < 0
    }
}

// MARK: - AccountListView

struct AccountListView: View {

    /// 返回上一级（与其他 Tab 一致的返回交互）
    let onBack: () -> Void

    @State private var items: [AccountRowItem] = []
    @State private var archivedItems: [AccountRowItem] = []
    @State private var netWorthData: (assets: Decimal, liabilities: Decimal, netWorth: Decimal) = (0, 0, 0)

    @State private var detailAccount: Account?
    @State private var showDetail = false
    @State private var showAddAccount = false
    @State private var editingAccount: Account?
    @State private var adjustingAccount: Account?

    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    netWorthCard

                    if items.isEmpty {
                        emptyStateView
                    } else {
                        accountListSection
                    }

                    if !archivedItems.isEmpty {
                        archivedSection
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.xs)
            }
            // 背景贯穿到导航栏/状态栏后面，避免玻璃导航栏下露出黑底
            .background(Color.holoBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 88)
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                    // 添加账户唯一入口，无障碍标签供读屏与 UI 测试定位
                    .accessibilityLabel("添加账户")
                }
            }
            .navigationDestination(isPresented: $showDetail) {
                if let account = detailAccount {
                    AccountDetailView(account: account)
                }
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet(mode: .create) { _ in loadData() }
            }
            .sheet(item: $editingAccount) { account in
                AddAccountSheet(mode: .edit(account)) { _ in loadData() }
            }
            .sheet(item: $adjustingAccount) { account in
                AdjustBalanceSheet(account: account) { loadData() }
            }
            .alert("操作失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .onAppear { loadData() }
            // 从账户详情返回后刷新（详情内可能改了余额/归档/删除）
            .onChange(of: showDetail) { _, showing in
                if !showing { loadData() }
            }
        }
    }

    // MARK: - 净资产卡（暖深褐材质 + 品牌橙负债比例条）

    private var netWorthCard: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("总净资产 · NET WORTH")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.1)
                .foregroundColor(Color(hex: "#F0C9A8"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatAmount(netWorthData.netWorth))
                .font(.system(size: 31, weight: .heavy, design: .rounded))
                .foregroundColor(netWorthData.netWorth >= 0 ? Color(hex: "#FFE8D5") : AccountCardMaterial.debtColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: HoloSpacing.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总资产 ASSETS")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#F0C9A8"))
                    Text(formatAmount(netWorthData.assets))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "#7EE2A8"))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("总负债 LIABILITIES")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#F0C9A8"))
                    Text(formatAmount(netWorthData.liabilities))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(AccountCardMaterial.debtColor)
                }
            }

            // 资产/负债比例条：暖绿 vs 品牌橙
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(LinearGradient(colors: [Color(hex: "#35A06D"), Color(hex: "#7EE2A8")], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * assetRatio)
                        LinearGradient(colors: [Color.holoPrimaryDark, Color(hex: "#F59E0B")], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * (1 - assetRatio))
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(height: 3)
        }
        .padding(20)
        .modifier(AccountCardMaterial(palette: netWorthPalette, isCurrent: false))
        .overlay(
            RoundedRectangle(cornerRadius: AccountCardMaterial.cornerRadius, style: .continuous)
                .strokeBorder(Color(hex: "#FED7AA").opacity(0.38), lineWidth: 1)
        )
    }

    private var netWorthPalette: AccountCardPalette {
        AccountCardPalette(
            c1: Color(hex: "#1C1614"),
            c2: Color(hex: "#2A1B15"),
            c3: Color(hex: "#321E18"),
            accent: .holoPrimaryDark
        )
    }

    private var assetRatio: CGFloat {
        let total = netWorthData.assets + netWorthData.liabilities
        guard total > 0 else { return 1 }
        let ratio = NSDecimalNumber(decimal: netWorthData.assets / total).doubleValue
        return min(max(CGFloat(ratio), 0), 1)
    }

    // MARK: - 账户列表（单卡容器，N 行平铺）

    private var accountListSection: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                accountRow(item: item, isArchived: false)
                if item.id != items.last?.id {
                    Divider()
                        .background(Color.holoDivider.opacity(0.55))
                        .padding(.leading, 68)
                }
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    // MARK: 已归档账户（不计入净资产）

    @ViewBuilder
    private var archivedSection: some View {
        VStack(spacing: 0) {
            Text("已归档 · \(archivedItems.count) 个（不计入净资产）")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(archivedItems) { item in
                accountRow(item: item, isArchived: true)
                if item.id != archivedItems.last?.id {
                    Divider()
                        .background(Color.holoDivider.opacity(0.55))
                        .padding(.leading, 68)
                }
            }
        }
        .background(Color.holoCardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: 账户行

    private func accountRow(item: AccountRowItem, isArchived: Bool) -> some View {
        let palette = AccountCardPalette.palette(for: item.account)
        return Button {
            guard !isArchived else { return }
            detailAccount = item.account
            showDetail = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.accent.opacity(0.16))
                    Image(systemName: item.account.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(palette.accent)
                }
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.accent.opacity(0.25), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.account.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                        if item.account.isDefault && !isArchived {
                            Text("默认")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.holoPrimaryDark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.10)))
                        }
                        if isArchived {
                            Text("已归档")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.holoGlassBackground))
                        }
                    }
                    Text("\(item.account.accountType.displayName) · \(item.account.accountType.englishLabel)")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(displayAmount(for: item))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(rowAmountColor(for: item))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(rowAmountLabel(for: item))
                        .font(.system(size: 9.5))
                        .tracking(0.6)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isArchived)
        .contextMenu {
            if !isArchived {
                Button { editingAccount = item.account } label: {
                    Label("编辑账户", systemImage: "pencil")
                }
                Button { adjustingAccount = item.account } label: {
                    Label("调整余额", systemImage: "arrow.triangle.2.circlepath")
                }
                if item.account.isDefault {
                    Label("设为默认（当前默认）", systemImage: "star.fill")
                } else {
                    Button {
                        FinanceRepository.shared.setDefaultAccount(item.account)
                        loadData()
                    } label: {
                        Label("设为默认", systemImage: "star")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    do {
                        try FinanceRepository.shared.archiveAccount(item.account)
                        loadData()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                } label: {
                    Label("归档账户", systemImage: "archivebox")
                }
            }
        }
    }

    /// 行内金额：信用卡欠款显示「已用额度」，普通负余额显示「负债」
    private func displayAmount(for item: AccountRowItem) -> String {
        if let outstanding = item.outstanding {
            return "¥\(AccountCardFormat.amount(outstanding))"
        }
        return AccountCardFormat.prefixed(item.balance)
    }

    private func rowAmountLabel(for item: AccountRowItem) -> String {
        if item.outstanding != nil { return "已用额度" }
        return item.isDebt ? "负债" : "当前余额"
    }

    private func rowAmountColor(for item: AccountRowItem) -> Color {
        (item.isDebt || item.outstanding != nil) ? AccountCardMaterial.debtColor : .holoTextPrimary
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("还没有账户")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Button {
                showAddAccount = true
            } label: {
                Text("添加第一个账户")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.holoPrimary))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - 数据

    private func loadData() {
        let all = FinanceRepository.shared.getAccounts(includeArchived: true)
        items = all.filter { !$0.isArchived }.map { account in
            AccountRowItem(
                account: account,
                balance: FinanceRepository.shared.getAccountBalance(account)
            )
        }
        archivedItems = all.filter { $0.isArchived }.map { account in
            AccountRowItem(
                account: account,
                balance: FinanceRepository.shared.getAccountBalance(account)
            )
        }
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
