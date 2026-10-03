//
//  AccountTabView.swift
//  Holo
//
//  统计分析「账户」页签（2026-10-03 东林定稿五页签方案）：
//  - 列表层：按本期支出排序的账户列表（支出+收入两列，归档分区在后），点行进子视图
//  - 子视图：账户头卡（余额 + 本期收支）+ 本期汇总/趋势（含余额线）/分类构成/流水
//  - 时间完全跟随顶部时间胶囊；看账户全程由用户调自定义时间（东林拍板不加快捷按钮）
//

import SwiftUI

struct AccountTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    @State private var selectedAccount: Account?

    var body: some View {
        Group {
            if let account = selectedAccount {
                AccountInsightView(state: state, account: account) {
                    selectedAccount = nil
                }
            } else {
                listView
            }
        }
        .background(Color.holoToolBackground)
    }

    // MARK: - 列表层

    private var activeAccounts: [Account] {
        state.availableAccounts.filter { !$0.isArchived }
    }

    private var archivedAccounts: [Account] {
        state.availableAccounts.filter { $0.isArchived }
    }

    /// 本期支出/收入查表（accountAggregations 只含有交易的账户，无交易账户不显示金额）
    private var aggByAccount: [UUID: AccountAggregation] {
        Dictionary(state.accountAggregations.map { ($0.account.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    private var listView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                HStack(spacing: HoloSpacing.sm) {
                    ScopeHeadCell(
                        title: String(localized: "账户支出合计"),
                        value: NumberFormatter.compactCurrency(totalSpent),
                        subtitle: rangeSubtitle,
                        valueColor: .holoError
                    )
                    ScopeHeadCell(
                        title: String(localized: "支出第一"),
                        value: topAccountName,
                        subtitle: String(localized: "\(state.availableAccounts.count) 个账户")
                    )
                }

                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text(String(localized: "按本期支出排序"))
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)

                    ForEach(activeAccounts, id: \.id) { account in
                        accountRow(account, aggregation: aggByAccount[account.id])
                    }

                    if !archivedAccounts.isEmpty {
                        Text(String(localized: "已归档"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.holoToolTextSecondary)
                            .padding(.top, HoloSpacing.sm)

                        ForEach(archivedAccounts, id: \.id) { account in
                            accountRow(account, aggregation: aggByAccount[account.id], isArchived: true)
                        }
                    }
                }
                .padding(HoloSpacing.md)
                .holoSurface()
            }
            .padding(HoloSpacing.lg)
        }
    }

    private var totalSpent: Decimal {
        state.accountAggregations.reduce(Decimal(0)) { $0 + $1.expense }
    }

    private var topAccountName: String {
        guard let top = state.accountAggregations.first(where: { $0.expense > 0 }),
              totalSpent > 0 else { return "—" }
        let pct = Int(Double(truncating: (top.expense / totalSpent * 100) as NSDecimalNumber))
        return "\(top.account.name) \(pct)%"
    }

    private var rangeSubtitle: String {
        let (start, end) = state.currentDateRange
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(df.string(from: start)) - \(df.string(from: end.addingDays(-1)))"
    }

    private func accountRow(_ account: Account, aggregation: AccountAggregation?, isArchived: Bool = false) -> some View {
        Button {
            selectedAccount = account
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(account.swiftUIColor.opacity(0.16))
                    Image(systemName: account.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(account.swiftUIColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoToolText)
                            .lineLimit(1)

                        if isArchived {
                            Text(String(localized: "已归档"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.holoToolTextSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoToolBackground))
                        }
                    }

                    // 占比横条（无支出账户不画）
                    if let spent = aggregation?.expense, spent > 0, totalSpent > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.holoDivider.opacity(0.4))
                                Capsule()
                                    .fill(account.swiftUIColor.opacity(0.75))
                                    .frame(width: max(4, geo.size.width * min(max(Double(truncating: (spent / totalSpent) as NSDecimalNumber), 0), 1)))
                            }
                        }
                        .frame(height: 5)
                    } else {
                        Color.clear.frame(height: 5)
                    }
                }

                Spacer(minLength: HoloSpacing.sm)

                VStack(alignment: .trailing, spacing: 2) {
                    if let spent = aggregation?.expense, spent > 0 {
                        Text(NumberFormatter.compactCurrency(spent))
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.holoToolText)
                    } else {
                        Text(String(localized: "无支出"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextPlaceholder)
                    }

                    if let income = aggregation?.income, income > 0 {
                        Text(String(localized: "收入 \(NumberFormatter.compactCurrency(income))"))
                            .font(.system(size: 10))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 账户子视图

private struct AccountInsightView: View {
    @ObservedObject var state: FinanceAnalysisState
    let account: Account
    var onBack: () -> Void

    @State private var insight: FinanceAnalysisState.ScopeInsight?
    @State private var balance: Decimal = 0

    /// 分类筛选（点分类横条展开二级+筛流水），时间范围取自全局时间档
    @StateObject private var categoryFilter: ScopeCategoryFilterModel

    init(state: FinanceAnalysisState, account: Account, onBack: @escaping () -> Void) {
        self.state = state
        self.account = account
        self.onBack = onBack
        _categoryFilter = StateObject(wrappedValue: ScopeCategoryFilterModel(
            scope: StatisticsScope(accountId: account.id, financeProjectId: nil),
            dateRange: { state.currentDateRange }
        ))
    }

    private var reloadKey: String {
        let (start, end) = state.currentDateRange
        return "\(account.id.uuidString)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                ScopeSubHeaderView(title: account.name, onBack: onBack)

                headerCard

                if let insight {
                    summaryCard(insight)
                    // 账户是资金容器，保留余额线（起点 = 该账户累计余额）
                    TrendChartView(dataPoints: insight.chartPoints)

                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        Text(String(localized: "分类构成"))
                            .font(.holoLabel)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoToolText)
                        ScopeCategoryBars(
                            aggregations: insight.expenseAggregations,
                            selectedCategoryId: categoryFilter.selectedTop?.id,
                            selectedSubCategoryId: categoryFilter.selectedSub?.id,
                            subAggregations: categoryFilter.subAggregations,
                            onSelect: { item in
                                withAnimation(HoloAnimation.quick) {
                                    categoryFilter.tapTop(item)
                                }
                            },
                            onSelectSub: { item in
                                withAnimation(HoloAnimation.quick) {
                                    categoryFilter.tapSub(item)
                                }
                            }
                        )
                    }
                    .padding(HoloSpacing.md)
                    .holoSurface()

                    transactionSection(insight)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
                        .padding(.vertical, HoloSpacing.xl)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoToolBackground)
        .task(id: reloadKey) {
            // 时间档变化后二级聚合随旧范围过期，连筛选一起复位
            categoryFilter.reset()
            balance = FinanceRepository.shared.getAccountBalance(account)
            insight = await state.loadScopeInsight(
                scope: StatisticsScope(accountId: account.id, financeProjectId: nil)
            )
        }
    }

    // MARK: 交易流水（随分类筛选联动）

    private func transactionSection(_ insight: FinanceAnalysisState.ScopeInsight) -> some View {
        let visible = categoryFilter.filter(insight.transactions)
        // 筛选态显示全部命中并带笔数；无筛选维持最近 30 条防长列表
        let display = categoryFilter.hasFilter ? visible.reversed() : visible.suffix(30).reversed()

        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Text(categoryFilter.hasFilter
                     ? String(localized: "交易流水 · \(visible.count) 笔")
                     : String(localized: "交易流水"))
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)

                if let label = categoryFilter.filterLabelText {
                    Button {
                        withAnimation(HoloAnimation.quick) {
                            categoryFilter.reset()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(label)
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            if visible.isEmpty {
                Text(insight.transactions.isEmpty
                     ? String(localized: "该时间范围内无交易")
                     : String(localized: "该分类在此范围无交易"))
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.md)
            } else {
                ForEach(display, id: \.id) { txn in
                    ScopeTxnRow(transaction: txn)
                }
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    // MARK: 头卡

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                    Image(systemName: account.icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text("\(account.accountType.displayName)\(account.isArchived ? " · \(String(localized: "已归档"))" : "")")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.85))
                }

                Spacer(minLength: 4)
            }

            HStack(spacing: 0) {
                headerStat(
                    title: String(localized: "当前余额"),
                    value: NumberFormatter.compactCurrency(balance),
                    highlight: balance < 0
                )

                if let insight {
                    Divider().frame(height: 32).overlay(Color.white.opacity(0.3))
                    headerStat(title: String(localized: "本期支出"), value: NumberFormatter.compactCurrency(insight.summary.totalExpense), highlight: true)
                    Divider().frame(height: 32).overlay(Color.white.opacity(0.3))
                    headerStat(title: String(localized: "本期收入"), value: NumberFormatter.compactCurrency(insight.summary.totalIncome), highlight: false)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(LinearGradient(
                    colors: [account.swiftUIColor, account.swiftUIColor.opacity(0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
    }

    private func headerStat(title: String, value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    // MARK: 本期汇总

    private func summaryCard(_ insight: FinanceAnalysisState.ScopeInsight) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack {
                Text(String(localized: "本期汇总"))
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                Spacer()
                Text(TimeRange.pillLabel(timeRange: state.timeRange, start: state.currentDateRange.start, end: state.currentDateRange.end))
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
            }

            HStack(spacing: 0) {
                ScopeHeadCell(title: String(localized: "支出"), value: insight.summary.formattedExpense, subtitle: "\(insight.summary.transactionCount) 笔", valueColor: .holoError)
                ScopeHeadCell(title: String(localized: "收入"), value: insight.summary.formattedIncome, subtitle: "")
                ScopeHeadCell(
                    title: String(localized: "净额"),
                    value: NumberFormatter.compactCurrency(insight.summary.netIncome),
                    subtitle: "",
                    valueColor: insight.summary.netIncome >= 0 ? .holoSuccess : .holoError
                )
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}
