//
//  AccountListView.swift
//  Holo
//
//  账户总览页 - 财务模块底部第 1 个 Tab
//  净资产卡 + 钱包式账户卡堆（点卡头翻卡/上下滑动/信息联动）+ 可切换的全部账户管理列表
//  视觉规范见 docs/design-mockups/finance-account-cards-brand.html
//

import SwiftUI

extension Account: Identifiable {}

struct AccountListView: View {

    /// 返回上一级（与其他 Tab 一致的返回交互）
    let onBack: () -> Void

    /// 记住上次置顶的账户，下次进入自动置顶
    @AppStorage("finance.accountStack.topAccountId") private var storedTopId: String?

    @State private var items: [AccountStackItem] = []
    @State private var archivedItems: [AccountStackItem] = []
    @State private var netWorthData: (assets: Decimal, liabilities: Decimal, netWorth: Decimal) = (0, 0, 0)
    @State private var dynData: AccountDynamicData?
    @State private var showListView = false

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
                ZStack(alignment: .top) {
                    // 环境光：随当前选中卡变色的顶部微光（克制：只铺净资产卡区域）
                    LinearGradient(
                        colors: [ambientColor.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.7), value: currentTopId)

                    VStack(spacing: HoloSpacing.md) {
                        netWorthCard

                        if items.isEmpty {
                            emptyStateView
                        } else if showListView {
                            manageListSection
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        } else {
                            stackSection
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.xs)
                }
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
            .onChange(of: currentTopId) { _, _ in loadDynData() }
            // 从账户详情返回后刷新（详情内可能改了余额/归档/删除）
            .onChange(of: showDetail) { _, showing in
                if !showing { loadData() }
            }
        }
    }

    // MARK: - 卡堆区

    private var stackSection: some View {
        VStack(spacing: HoloSpacing.md) {
            AccountCardStackView(
                items: items,
                topAccountId: topBinding,
                onOpenDetail: { account in
                    detailAccount = account
                    showDetail = true
                },
                onAddAccount: { showAddAccount = true },
                onEdit: { account in editingAccount = account },
                onAdjustBalance: { account in adjustingAccount = account },
                onSetDefault: { account in
                    FinanceRepository.shared.setDefaultAccount(account)
                    loadData()
                },
                onArchive: { account in
                    do {
                        try FinanceRepository.shared.archiveAccount(account)
                        loadData()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            )

            if let top = currentTopAccount, let dynData {
                AccountDynamicPanel(account: top, data: dynData) { account in
                    detailAccount = account
                    showDetail = true
                }
                .id(top.id) // 切卡时整体过渡，避免内容串帧
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(HoloAnimation.standard, value: currentTopId)
    }

    // MARK: - 净资产卡（Holo 暖深褐 + 品牌橙负债比例条）

    private var netWorthCard: some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("总净资产 · NET WORTH")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.1)
                    .foregroundColor(Color(hex: "#F0C9A8"))
                Spacer()
                Button {
                    withAnimation(HoloAnimation.standard) { showListView.toggle() }
                } label: {
                    Text(showListView ? "‹ 卡堆视图" : "› 卡片视图")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#F0C9A8"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(Color(hex: "#FED7AA").opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Text(formatAmount(netWorthData.netWorth))
                .font(.system(size: 31, weight: .heavy, design: .rounded))
                .foregroundColor(netWorthData.netWorth >= 0 ? Color(hex: "#FFE8D5") : Color(hex: "#FFA98F"))
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
                        .foregroundColor(Color(hex: "#FFA98F"))
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

    // MARK: - 全部账户管理列表（卡片视图）

    private var manageListSection: some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("全部账户 · \(items.count + archivedItems.count) 个")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 4)
            // 返回卡堆统一走净资产卡右上角的「‹ 卡堆视图」，这里不再放第二个入口

            VStack(spacing: 0) {
                Text("使用中 · \(items.count) 个")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(items) { item in
                    manageRow(item: item, isArchived: false)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5))

            if !archivedItems.isEmpty {
                VStack(spacing: 0) {
                    Text("已归档 · \(archivedItems.count) 个（不计入净资产）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(archivedItems) { item in
                        manageRow(item: item, isArchived: true)
                    }
                }
                .background(Color.holoCardBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5))
            }
        }
    }

    private func manageRow(item: AccountStackItem, isArchived: Bool) -> some View {
        let accent = AccountCardPalette.palette(for: item.account).accent
        return Button {
            if isArchived { return }
            storedTopId = item.id.uuidString
            withAnimation(HoloAnimation.standard) { showListView = false }
            loadDynData()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.12))
                    Image(systemName: item.account.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(accent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.account.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
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

                Spacer()

                if isArchived {
                    Button {
                        FinanceRepository.shared.unarchiveAccount(item.account)
                        loadData()
                    } label: {
                        Text("解归档")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoPrimaryDark)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.holoPrimary.opacity(0.09)))
                            .overlay(Capsule().strokeBorder(Color.holoPrimaryDark.opacity(0.22), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("¥\(AccountCardFormat.amount(item.balance))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(item.balance >= 0 ? .holoTextPrimary : .holoError)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// 卡堆置顶账户的双向绑定（AppStorage 存字符串）
    private var topBinding: Binding<UUID?> {
        Binding(
            get: { storedTopId.flatMap(UUID.init(uuidString:)) },
            set: { storedTopId = $0?.uuidString }
        )
    }

    private var currentTopId: UUID? {
        topBinding.wrappedValue ?? items.first?.id
    }

    private var currentTopAccount: Account? {
        items.first { $0.id == currentTopId }?.account ?? items.first?.account
    }

    private var ambientColor: Color {
        currentTopAccount.map { AccountCardPalette.palette(for: $0).accent } ?? .holoPrimary
    }

    private func loadData() {
        let all = FinanceRepository.shared.getAccounts(includeArchived: true)
        let active = all.filter { !$0.isArchived }
        archivedItems = all.filter { $0.isArchived }.map { account in
            AccountStackItem(
                account: account,
                balance: FinanceRepository.shared.getAccountBalance(account),
                monthlyIncome: 0,
                monthlyExpense: 0
            )
        }

        items = active.map { account in
            let balance = FinanceRepository.shared.getAccountBalance(account)
            let monthly = FinanceRepository.shared.getAccountMonthlySummary(accountId: account.id, month: Date())
            return AccountStackItem(
                account: account,
                balance: balance,
                monthlyIncome: monthly.income,
                monthlyExpense: monthly.expense
            )
        }

        netWorthData = FinanceRepository.shared.getTotalNetWorth()

        // 置顶账户失效（删除/归档）时回落到第一个
        if let id = topBinding.wrappedValue, !active.contains(where: { $0.id == id }) {
            storedTopId = active.first?.id.uuidString
        }

        loadDynData()
    }

    private func loadDynData() {
        guard let top = currentTopAccount else {
            dynData = nil
            return
        }
        dynData = AccountDynamicData.load(for: top)
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}
