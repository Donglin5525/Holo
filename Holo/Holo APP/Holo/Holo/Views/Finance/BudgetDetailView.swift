//
//  BudgetDetailView.swift
//  Holo
//
//  预算详情页 — 严格预算模式反馈闭环的统一落点（2026-09-27 方案一期）
//  看板预算卡 / 账本页预算总览卡 / 结转通知与横幅三处触点共用：
//  额度构成（原额度 − 上期超支结转）放主舞台，严格开关与预算编辑就近收口，
//  替代「财务设置深处找开关」的旧动线。二期月度结算单与连续达标在此页生长。
//

import SwiftUI

struct BudgetDetailView: View {

    /// 锚定账户；nil = 全部账户汇总（与看板预算卡口径一致）
    let anchoredAccountId: UUID?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var budgetSettings = FinanceBudgetSettings.shared

    @State private var accounts: [Account] = []
    @State private var selectedAccountId: UUID?
    @State private var todayExpense: Decimal?
    @State private var showRulesSheet = false
    @State private var showBudgetEditor = false
    @State private var categoryOverviews: [CategoryBudgetOverview] = []
    @State private var selectedOverview: CategoryBudgetOverview?
    @State private var showCategoryBudgetEditor = false
    @State private var editorAccount: Account?
    @State private var showAccountPicker = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    if accounts.count > 1 {
                        accountSwitcher
                    }
                    compositionCard
                    statGrid
                    categoryBudgetSection
                    strictModeCard
                    if selectedAccountId != nil {
                        editBudgetButton
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xl)
            }
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "预算"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showRulesSheet) { rulesSheet }
        .sheet(isPresented: $showBudgetEditor) { budgetEditor }
        .sheet(item: $selectedOverview) { overview in
            BudgetCategoryDetailSheet(categoryId: overview.categoryId, accountId: selectedAccountId)
        }
        .sheet(isPresented: $showCategoryBudgetEditor) {
            if let account = editorAccount {
                BudgetSettingsSheet(account: account, initialMode: .category) { }
            }
        }
        .confirmationDialog(
            String(localized: "给哪个账户添加预算？"),
            isPresented: $showAccountPicker,
            titleVisibility: .visible
        ) {
            ForEach(accounts, id: \.id) { account in
                Button(account.name) {
                    editorAccount = account
                    showCategoryBudgetEditor = true
                }
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            reload()
        }
    }

    // MARK: - 账户切换（沿用看板预算卡模式）

    private var accountSwitcher: some View {
        HStack {
            Spacer()
            Menu {
                Button {
                    selectedAccountId = nil
                    reload()
                } label: {
                    Label(String(localized: "全部账户"), systemImage: selectedAccountId == nil ? "checkmark" : "")
                }
                ForEach(accounts, id: \.id) { account in
                    Button {
                        selectedAccountId = account.id
                        reload()
                    } label: {
                        Label(account.name, systemImage: selectedAccountId == account.id ? "checkmark" : "")
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
    }

    private var selectedAccountName: String {
        if let selected = accounts.first(where: { $0.id == selectedAccountId }) {
            return selected.name
        }
        return String(localized: "全部账户")
    }

    // MARK: - 额度构成卡（主舞台）

    /// 单账户态的预算状态；全部账户态为 nil
    private var accountStatus: BudgetStatus? {
        guard let id = selectedAccountId else { return nil }
        return BudgetRepository.shared.computeTotalBudgetStatus(forAccount: id, period: .month)
    }

    /// 全部账户态的汇总；单账户态为 nil
    private var globalSummary: GlobalBudgetSummary? {
        guard selectedAccountId == nil else { return nil }
        return BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
    }

    private var compositionCard: some View {
        VStack(spacing: 12) {
            compositionHeader
            compositionBar
            if let note = carryoverNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        .shadow(color: HoloShadow.card, radius: 4, y: 1)
    }

    /// 汇总展示数据（两种口径统一取值，nil = 该账户未设置月度总预算）
    private var overview: (remaining: Decimal, over: Decimal, original: Decimal, deduction: Decimal, progress: Double, isOver: Bool)? {
        if let status = accountStatus {
            return (
                status.remainingAmount,
                max(0, status.spentAmount - status.effectiveAmount),
                status.budgetAmount,
                status.carryoverDeduction,
                status.progress,
                status.isOverBudget
            )
        }
        if let summary = globalSummary {
            return (
                summary.totalRemainingAmount,
                max(0, summary.totalSpentAmount - summary.totalBudgetAmount),
                summary.totalOriginalAmount,
                summary.totalCarryoverDeduction,
                summary.progress,
                summary.isOverBudget
            )
        }
        return nil
    }

    @ViewBuilder
    private var compositionHeader: some View {
        if let data = overview {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.isOver ? String(localized: "已超支") : String(localized: "本月剩余"))
                    .font(.holoLabel)
                    .foregroundColor(data.isOver ? .holoError : .holoTextSecondary)
                HStack(spacing: 4) {
                    if data.isOver {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.holoError)
                    }
                    Text(data.isOver
                         ? NumberFormatter.currency.string(from: NSDecimalNumber(decimal: data.over)) ?? "¥0"
                         : NumberFormatter.currency.string(from: NSDecimalNumber(decimal: data.remaining)) ?? "¥0")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(data.isOver ? .holoError : .holoTextPrimary)
                    Text("/ \(NumberFormatter.currency.string(from: NSDecimalNumber(decimal: data.deduction > 0 ? originalMinusDeduction(data) : data.original)) ?? "¥0")")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(String(localized: "该账户未设置月度预算"))
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 构成分母：严格模式开启且被结转时 = 原额度 − 结转（即有效额度）
    private func originalMinusDeduction(_ data: (remaining: Decimal, over: Decimal, original: Decimal, deduction: Decimal, progress: Double, isOver: Bool)) -> Decimal {
        max(0, data.original - data.deduction)
    }

    @ViewBuilder
    private var compositionBar: some View {
        if let data = overview {
            VStack(alignment: .trailing, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.holoDivider)
                            .frame(height: 6)
                        Capsule()
                            .fill(budgetProgressColor(data.progress))
                            .frame(width: max(geo.size.width * min(data.progress, 1.0), 0), height: 6)
                            .overlay {
                                if data.isOver {
                                    OverBudgetStripeOverlay()
                                        .clipShape(Capsule())
                                }
                            }
                            .animation(.spring(response: 0.5), value: data.progress)
                    }
                }
                .frame(height: 6)
                if data.isOver {
                    Text(String(localized: "超支 \(max(1, Int(ceil((data.progress - 1.0) * 100))))%"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoError)
                }
            }
        }
    }

    /// 结转构成行：把因果从看板 10pt 小字搬到主舞台
    private var carryoverNote: String? {
        guard let data = overview, data.deduction > 0 else { return nil }
        let deduction = NumberFormatter.currency.string(from: NSDecimalNumber(decimal: data.deduction)) ?? "¥0"
        let original = NumberFormatter.currency.string(from: NSDecimalNumber(decimal: data.original)) ?? "¥0"
        return String(localized: "上月超支结转 −\(deduction) · 原额度 \(original)")
    }

    // MARK: - 三格（沿用看板预算卡口径）

    private var statGrid: some View {
        HStack(spacing: 10) {
            statItem(
                label: String(localized: "今日支出"),
                value: todayExpenseText,
                color: .holoTextPrimary
            )
            statItem(
                label: String(localized: "日均可用"),
                value: dailyBudgetText,
                color: .holoInfo
            )
            statItem(
                label: String(localized: "剩余天数"),
                value: remainingDaysText,
                color: .holoSuccess
            )
        }
    }

    private var todayExpenseText: String {
        guard let todayExpense else { return String(localized: "加载中") }
        return NumberFormatter.currency.string(from: NSDecimalNumber(decimal: todayExpense)) ?? "¥0"
    }

    private var dailyBudgetText: String {
        guard let data = overview, !data.isOver else { return "¥0" }
        let days = remainingDays
        guard days > 0 else { return "¥0" }
        let daily = max(0, data.remaining) / Decimal(days)
        return NumberFormatter.currency.string(from: NSDecimalNumber(decimal: daily)) ?? "¥0"
    }

    private var remainingDays: Int {
        if let status = accountStatus { return status.remainingDays }
        if let summary = globalSummary { return summary.remainingDays }
        return 0
    }

    private var remainingDaysText: String {
        String(localized: "\(remainingDays)天")
    }

    private func statItem(label: String, value: String, color: Color) -> some View {
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

    // MARK: - 分类预算区（科目预算，点行看明细）

    private var categoryBudgetSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "分类预算"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Button {
                    gateBudget { startAddCategoryBudget() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text(String(localized: "添加"))
                            .font(.holoCaption)
                    }
                    .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if categoryOverviews.isEmpty {
                Button {
                    gateBudget { startAddCategoryBudget() }
                } label: {
                    VStack(spacing: HoloSpacing.sm) {
                        Image(systemName: "chart.pie")
                            .font(.system(size: 24))
                            .foregroundColor(.holoTextSecondary.opacity(0.4))
                        Text(String(localized: "给重点科目单独设预算，如餐饮、购物"))
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.lg)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(categoryOverviews) { overview in
                        categoryBudgetRow(overview)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    /// 点击行 = 看该科目的花销明细（预算闭环的核心一跳）
    private func categoryBudgetRow(_ overview: CategoryBudgetOverview) -> some View {
        Button {
            selectedOverview = overview
        } label: {
            HStack(spacing: HoloSpacing.md) {
                CategoryIconBadge(
                    iconName: overview.categoryIcon,
                    color: Color(hex: overview.categoryColor),
                    diameter: 32
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(overview.categoryName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                        if overview.statuses.count > 1 {
                            Text(String(localized: "\(overview.statuses.count) 账户"))
                                .font(.system(size: 10))
                                .foregroundColor(.holoTextPlaceholder)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.holoBackground)
                                .clipShape(Capsule())
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.holoBorder.opacity(0.3))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(budgetProgressColor(overview.progress))
                                .frame(width: geo.size.width * min(CGFloat(overview.progress), 1.0), height: 4)
                        }
                    }
                    .frame(height: 4)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(overview.progress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(budgetProgressColor(overview.progress))
                    if overview.isOverBudget {
                        Text(String(localized: "超支 \(formatAmount(overview.totalRemainingAmount))"))
                            .font(.system(size: 10))
                            .foregroundColor(.holoError)
                    } else {
                        Text(String(localized: "剩余 \(formatAmount(overview.totalRemainingAmount))"))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    /// 添加分类预算：单账户视角（或仅一个账户）直接进设置；全部账户视角多账户时先选账户
    private func startAddCategoryBudget() {
        if let id = selectedAccountId, let account = accounts.first(where: { $0.id == id }) {
            editorAccount = account
            showCategoryBudgetEditor = true
        } else if accounts.count == 1, let only = accounts.first {
            editorAccount = only
            showCategoryBudgetEditor = true
        } else {
            showAccountPicker = true
        }
    }

    /// 预算编辑为 Plus 权益：非 Plus 弹付费墙，购买成功后回开原入口；存量预算展示不受影响
    private func gateBudget(_ open: @escaping () -> Void) {
        guard HoloEntitlementState.shared.isPlusActive else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .budget, resume: open)
            return
        }
        open()
    }

    private func formatAmount(_ amount: Decimal) -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: abs(amount))) ?? "¥0"
    }

    // MARK: - 严格模式开关区

    private var strictModeCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "严格预算模式"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Button {
                    showRulesSheet = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "规则说明"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if selectedAccountId != nil {
                strictToggleRow(
                    title: String(localized: "超支结转到下月"),
                    isOn: strictBinding(selectedAccountId!)
                )
            } else {
                ForEach(accounts, id: \.id) { account in
                    strictToggleRow(
                        title: account.name,
                        isOn: strictBinding(account.id)
                    )
                }
            }
        }
        .padding(.bottom, 10)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
    }

    private func strictToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func strictBinding(_ accountId: UUID) -> Binding<Bool> {
        Binding(
            get: { budgetSettings.isEnabled(for: accountId) },
            set: { $0 ? budgetSettings.enable(for: accountId) : budgetSettings.disable(for: accountId) }
        )
    }

    // MARK: - 预算编辑入口（单账户态）

    private var editBudgetButton: some View {
        Button {
            gateBudget { showBudgetEditor = true }
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                Text(String(localized: "编辑预算额度"))
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.holoPrimary)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
        .buttonStyle(.plain)
    }

    private var budgetEditor: some View {
        Group {
            if let id = selectedAccountId,
               let account = accounts.first(where: { $0.id == id }) {
                BudgetSettingsSheet(
                    account: account,
                    existingBudget: BudgetRepository.shared.getTotalBudget(forAccount: id, period: .month),
                    initialMode: .total
                ) {
                    showBudgetEditor = false
                }
            }
        }
    }

    // MARK: - 规则说明弹层（与首次开启弹层共用内容）

    private var rulesSheet: some View {
        VStack(spacing: HoloSpacing.lg) {
            Text(String(localized: "严格预算模式怎么运作"))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.holoTextPrimary)
                .padding(.top, 24)

            BudgetStrictModeRulesContent()
                .padding(.horizontal, 20)

            Button {
                showRulesSheet = false
            } label: {
                Text(String(localized: "我知道了"))
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.holoPrimary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .holoSheetShell()
    }

    // MARK: - 数据

    private func reload() {
        accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        if selectedAccountId == nil, let anchored = anchoredAccountId {
            // 锚定账户已被删除时不锚定，回退全部账户
            if accounts.contains(where: { $0.id == anchored }) {
                selectedAccountId = anchored
            }
        }
        if let id = selectedAccountId, !accounts.contains(where: { $0.id == id }) {
            selectedAccountId = nil
        }
        loadTodayExpense()
        categoryOverviews = BudgetRepository.shared.computeMonthlyCategoryBudgetOverviews(accountId: selectedAccountId)
    }

    private func loadTodayExpense() {
        let accountId = selectedAccountId
        Task { @MainActor in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
            do {
                let transactions = try await FinanceRepository.shared.getStatisticsTransactions(from: start, to: end)
                todayExpense = transactions
                    .filter { transaction in
                        transaction.transactionType == .expense
                            && (accountId == nil || transaction.account?.id == accountId)
                    }
                    .reduce(Decimal.zero) { $0 + $1.amountAsDecimal }
            } catch {
                todayExpense = nil
            }
        }
    }
}

// MARK: - 规则说明共用块

/// 严格预算模式规则三行：详情页「规则说明」与首次开启弹层共用，
/// 单一事实源避免两处文案漂移
struct BudgetStrictModeRulesContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            BudgetStrictModeRulesContent.ruleRow(
                icon: "calendar",
                text: String(localized: "开启当月是起算期，之前的超支不追溯")
            )
            BudgetStrictModeRulesContent.ruleRow(
                icon: "square.split.2x1",
                text: String(localized: "仅作用于账户总预算，分类预算不结转")
            )
            BudgetStrictModeRulesContent.ruleRow(
                icon: "arrow.uturn.down.circle",
                text: String(localized: "超支多少，下月额度就扣多少（最低扣到 0）；不超支自动恢复原额度")
            )
        }
        .padding(.horizontal, 4)
    }

    private static func ruleRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.holoTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
