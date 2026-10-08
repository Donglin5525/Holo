//
//  BudgetCategoryDetailSheet.swift
//  Holo
//
//  科目预算明细弹层 — 预算详情页「分类预算」区点行进入
//  头部 = 该科目预算进度卡（全部账户视角下同科目多账户合并口径），
//  列表 = 预算口径明细（fetchBudgetExpense/RefundTransactions 与已花金额同源同谓词）：
//  支出笔与退款笔都展示，日汇总与合计按净额（支出 − 退款），保证明细加起来 = 已花，一笔不差。
//

import SwiftUI

struct BudgetCategoryDetailSheet: View {

    let categoryId: UUID
    /// 视角账户；nil = 全部账户（同科目跨账户合并展示）
    let accountId: UUID?

    @Environment(\.dismiss) private var dismiss

    @State private var overview: CategoryBudgetOverview?
    @State private var transactions: [Transaction] = []
    @State private var accounts: [Account] = []
    @State private var editingTransaction: Transaction?
    @State private var editingStatus: BudgetStatus?
    @State private var showEditPicker = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    if let overview {
                        progressCard(overview)
                        editBudgetButton(overview)
                        transactionList
                    } else {
                        emptyBudgetState
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(overview?.categoryName ?? String(localized: "分类预算"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in }
        }
        .sheet(item: $editingStatus) { status in
            Group {
                if let account = accounts.first(where: { $0.id == status.budget.accountId }) {
                    BudgetSettingsSheet(
                        account: account,
                        existingBudget: status.budget,
                        initialMode: .category
                    ) { }
                }
            }
        }
        .confirmationDialog(
            String(localized: "编辑哪个预算？"),
            isPresented: $showEditPicker,
            titleVisibility: .visible
        ) {
            if let overview {
                ForEach(overview.statuses) { status in
                    Button(editPickerLabel(status)) {
                        editingStatus = status
                    }
                }
            }
        }
        .onAppear { loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            loadData()
        }
    }

    // MARK: - 进度卡（合并口径，视觉语言与预算详情页主舞台一致）

    private func progressCard(_ overview: CategoryBudgetOverview) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: HoloSpacing.md) {
                CategoryIconBadge(
                    iconName: overview.categoryIcon,
                    color: Color(hex: overview.categoryColor),
                    diameter: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(overview.categoryName)
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                    if overview.statuses.count > 1 {
                        Text(String(localized: "已合并 \(overview.statuses.count) 个账户的预算"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextPlaceholder)
                    }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(overview.isOverBudget ? String(localized: "已超支") : String(localized: "本月剩余"))
                    .font(.holoLabel)
                    .foregroundColor(overview.isOverBudget ? .holoError : .holoTextSecondary)
                HStack(spacing: 4) {
                    if overview.isOverBudget {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.holoError)
                    }
                    Text(NumberFormatter.currency.string(from: NSDecimalNumber(decimal: overview.isOverBudget ? max(0, -overview.totalRemainingAmount) : overview.totalRemainingAmount)) ?? "¥0")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(overview.isOverBudget ? .holoError : .holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("/ \(NumberFormatter.currency.string(from: NSDecimalNumber(decimal: overview.totalBudgetAmount)) ?? "¥0")")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.holoDivider)
                            .frame(height: 6)
                        Capsule()
                            .fill(budgetProgressColor(overview.progress))
                            .frame(width: max(geo.size.width * min(overview.progress, 1.0), 0), height: 6)
                            .overlay {
                                if overview.isOverBudget {
                                    OverBudgetStripeOverlay()
                                        .clipShape(Capsule())
                                }
                            }
                            .animation(.spring(response: 0.5), value: overview.progress)
                    }
                }
                .frame(height: 6)
                if overview.isOverBudget {
                    Text(String(localized: "超支 \(max(1, Int(ceil((overview.progress - 1.0) * 100))))%"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoError)
                }
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
        .shadow(color: HoloShadow.card, radius: 4, y: 1)
    }

    private func editBudgetButton(_ overview: CategoryBudgetOverview) -> some View {
        Button {
            if overview.statuses.count > 1 {
                showEditPicker = true
            } else if let status = overview.statuses.first {
                editingStatus = status
            }
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                Text(String(localized: "编辑预算"))
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

    private func editPickerLabel(_ status: BudgetStatus) -> String {
        let accountName = accounts.first(where: { $0.id == status.budget.accountId })?.name ?? String(localized: "未知账户")
        let amount = NumberFormatter.currency.string(from: NSDecimalNumber(decimal: status.budgetAmount)) ?? "¥0"
        return "\(accountName) · \(amount)"
    }

    // MARK: - 明细列表（按天分组，日汇总按净额）

    private var transactionList: some View {
        Group {
            if transactions.isEmpty {
                emptyTransactionState
            } else {
                groupedTransactionView
                totalFooter
            }
        }
    }

    private var groupedTransactionView: some View {
        let grouped = Dictionary(grouping: transactions) { tx in
            Calendar.current.startOfDay(for: tx.date)
        }

        return VStack(spacing: HoloSpacing.lg) {
            ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    dateHeader(date: date, dayTxns: grouped[date] ?? [])

                    VStack(spacing: 0) {
                        ForEach(grouped[date] ?? []) { tx in
                            TransactionRowView(transaction: tx) {
                                editingTransaction = tx
                            }
                            if tx.id != grouped[date]?.last?.id {
                                Divider().padding(.leading, 72)
                            }
                        }
                    }
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
            }
        }
    }

    private func dateHeader(date: Date, dayTxns: [Transaction]) -> some View {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        let net = dayTxns.reduce(Decimal(0)) { sum, tx in
            tx.transactionType == .expense
                ? sum + tx.amount.decimalValue
                : sum - tx.amount.decimalValue
        }

        return HStack {
            Text(df.string(from: date))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            if net != 0 {
                Text("-\(NumberFormatter.currency.string(from: NSDecimalNumber(decimal: net)) ?? "")")
                    .font(.system(size: 12))
                    .foregroundColor(.holoError)
            }
        }
        .padding(.horizontal, HoloSpacing.xs)
    }

    /// 对账行：列表净额合计 = 头部已花，用户可逐日对账
    private var totalFooter: some View {
        HStack {
            Text(String(localized: "本月合计 · \(transactions.filter { $0.transactionType == .expense }.count) 笔"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            if let overview {
                Text(String(localized: "已花 \(NumberFormatter.currency.string(from: NSDecimalNumber(decimal: overview.totalSpentAmount)) ?? "¥0")"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
            }
        }
        .padding(.horizontal, HoloSpacing.xs)
    }

    // MARK: - 空态

    private var emptyTransactionState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text(String(localized: "本月该科目还没有支出"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    private var emptyBudgetState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "chart.pie")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text(String(localized: "该科目的预算已删除"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    // MARK: - 数据（明细与已花同源：同款预算口径查询）

    private func loadData() {
        accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        guard let current = BudgetRepository.shared.computeCategoryBudgetOverview(categoryId: categoryId, accountId: accountId) else {
            overview = nil
            transactions = []
            return
        }
        overview = current

        var all: [Transaction] = []
        for status in current.statuses {
            let range = (start: status.periodStartDate, end: status.periodEndDate)
            let budgetAccountId = status.budget.accountId
            all += BudgetRepository.shared.fetchBudgetExpenseTransactions(
                range: range, accountId: budgetAccountId, categoryId: categoryId
            )
            all += BudgetRepository.shared.fetchBudgetRefundTransactions(
                range: range, accountId: budgetAccountId, categoryId: categoryId
            )
        }
        transactions = all.sorted { $0.date > $1.date }
    }
}
