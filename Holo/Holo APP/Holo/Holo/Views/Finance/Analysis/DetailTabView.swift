//
//  DetailTabView.swift
//  Holo
//
//  明细 Tab 视图
//  收支趋势柱状卡（与总览/项目/账户同款）固定在顶部 + 交易明细独立滚动
//  支持按粒度下钻显示数据
//

import SwiftUI

/// 缓存的日期格式器：图表逐日取标签、列表分组头/时段标题逐行取文案，
/// 内联新建是每次渲染的持续开销（体检 R0-5）
private enum DetailTabFormatters {
    static let dayLabel: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M.d"
        return df
    }()

    static let dayWeekday: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return df
    }()
}

// MARK: - DetailTabView

/// 明细 Tab 视图：
/// 紧凑无卡趋势图与「交易明细」头常驻固定在顶部（2026-10-30 东林拍板交互：
/// 图表不动、下方明细独立滚动，横滑/点柱实时定位下方列表；
/// 2026-11-26 去掉白卡外壳与冗余读数后压缩图表区高度，首屏即可直出 5-6 条明细）
struct DetailTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    /// push 覆盖层模式：外层已带返回栏与分类标题，分类筛选横幅不在本页重复出现
    var isPushed: Bool = false
    @State private var editingTransaction: Transaction?
    @State private var sortOrder: FinanceDetailSortOrder = .timeDescending
    @State private var listScrollTarget: Date?
    @State private var listScrollRequestID = 0

    private var filteredTransactions: [Transaction] {
        guard let category = state.selectedDetailCategory else {
            return state.transactions
        }
        return state.transactions.filter {
            state.transaction($0, matchesDetailCategory: category)
        }
    }

    private var filteredTotals: (expense: Decimal, income: Decimal) {
        let stats = filteredTransactions.filter { !$0.isReconciliationAdjustment }
        let exp = stats.filter { $0.statisticsType == .expense }.reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        let inc = stats.filter { $0.statisticsType == .income }.reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        return (exp, inc)
    }

    private var sortedFilteredTransactions: [Transaction] {
        filteredTransactions.sorted {
            sortOrder.areInIncreasingOrder(sortValue(for: $0), sortValue(for: $1))
        }
    }

    private var dailyChartDataPoints: [ChartDataPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            calendar.startOfDay(for: tx.date)
        }
        let range = state.currentDateRange
        var current = calendar.startOfDay(for: range.start)
        let effectiveEnd = FinanceAnalysisState.effectiveChartEnd(
            start: range.start,
            end: range.end,
            transactions: filteredTransactions,
            calendar: calendar
        )
        let end = calendar.startOfDay(for: effectiveEnd)
        var points: [ChartDataPoint] = []

        while current < end {
            let dayTxns = grouped[current] ?? []
            let expense = dayTxns
                .filter { $0.statisticsType == .expense }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
            let income = dayTxns
                .filter { $0.statisticsType == .income }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

            points.append(ChartDataPoint(
                date: current,
                label: DetailTabFormatters.dayLabel.string(from: current),
                expense: expense,
                income: income,
                transactionCount: dayTxns.count
            ))

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return points
    }

    var body: some View {
        // 趋势图与列表头常驻固定在顶部，滚动的只有下方交易明细；
        // 图表在滚动容器之外，横滑/点按选日实时联动列表定位，且不存在双层滚动顶牛。
        VStack(spacing: 0) {
            trendSection
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, 10)
                .padding(.bottom, 10)

            HoloHairlineDivider()

            transactionListHeader
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollViewReader { listProxy in
                ScrollView {
                    transactionListContent
                        .padding(.horizontal, HoloSpacing.page)
                        .padding(.bottom, HoloSpacing.xxl)
                }
                .scrollIndicators(.hidden)
                .onChange(of: listScrollRequestID) { _, _ in
                    guard let target = listScrollTarget else { return }
                    // 排序模式切换与列表重建发生在同一轮更新，下一帧再定位可确保锚点已存在。
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            listProxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(Color.holoToolBackground)
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in
                state.refresh()
            }
        }
    }

    private var trendSection: some View {
        let totals = filteredTotals
        let expText = NumberFormatter.currency.string(from: totals.expense as NSDecimalNumber) ?? "¥0.00"
        let incText = NumberFormatter.currency.string(from: totals.income as NSDecimalNumber) ?? "¥0.00"
        return VStack(spacing: HoloSpacing.sm) {
            if !isPushed, let category = state.selectedDetailCategory {
                categoryFilterBanner(category)
            }

            TrendChartView(
                dataPoints: dailyChartDataPoints,
                showsBalanceLine: false,
                selectedDate: state.selectedChartDate,
                onScrubDate: selectChartDateAndScroll,
                usesDayTickAnchors: true,
                isCardless: true,
                compactMode: true,
                compactSummary: (expense: expText, income: incText)
            )
        }
    }

    /// 趋势图负责选择日期，明细仍保留全量数据，只改变列表当前可见位置。
    /// 时间定位与金额排序语义冲突时自动回到“时间从新到旧”，避免日期锚点失真。
    private func selectChartDateAndScroll(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard dailyChartDataPoints.contains(where: {
            $0.hasTransactions && Calendar.current.isDate($0.date, inSameDayAs: day)
        }) else {
            return
        }

        sortOrder = sortOrder.orderForChartNavigation

        state.selectChartDate(day)
        listScrollTarget = day
        listScrollRequestID &+= 1
    }

    private func sortValue(for transaction: Transaction) -> FinanceDetailSortValue {
        FinanceDetailSortValue(
            id: transaction.id,
            date: transaction.date,
            amount: transaction.amount.decimalValue
        )
    }

    // MARK: - 分类筛选

    private func categoryFilterBanner(_ category: Category) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            transactionCategoryIcon(category, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(category.name)明细")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)

                Text("\(filteredTransactions.count) 笔 · 当前日期范围")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            Button {
                state.selectDetailCategory(nil)
            } label: {
                Text("清除")
                    .holoText(.supporting)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, HoloSpacing.xs)
                    .background(Color.holoPrimary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 全部交易列表

    private var transactionListHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text("交易明细")
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)

            Text("\(filteredTransactions.count) 笔")
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)

            Spacer()

            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FinanceDetailSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if sortOrder == order {
                        Label(order.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(order.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: sortOrder.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(sortOrder.compactTitle)
                    .font(.holoTinyLabel)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.holoPrimary.opacity(0.1))
            .clipShape(Capsule())
        }
        .accessibilityLabel(String(localized: "切换交易明细排序"))
        .accessibilityValue(sortOrder.menuTitle)
    }

    @ViewBuilder
    private var transactionListContent: some View {
        if filteredTransactions.isEmpty {
            emptyTransactionState
        } else if sortOrder.groupsByDay {
            groupedTransactionsView
        } else {
            amountSortedTransactionsView
        }
    }

    // MARK: - 分组交易列表

    private var groupedTransactionsView: some View {
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            Calendar.current.startOfDay(for: tx.date)
        }
        let dates = grouped.keys.sorted {
            sortOrder == .timeAscending ? $0 < $1 : $0 > $1
        }

        // 日组间距拉开到 md（2026-11-16 明细页降密度拍板）：扫读以「天」为节拍，
        // 呼吸感来自层次而不是放大行高
        return VStack(alignment: .leading, spacing: HoloSpacing.md) {
            ForEach(dates, id: \.self) { date in
                let dayTransactions = sortedTransactions(grouped[date] ?? [])

                VStack(alignment: .leading, spacing: 2) {
                    dateHeader(date: date, transactions: dayTransactions)
                    compactTransactionRows(dayTransactions, showsDate: false)
                }
            }
        }
    }

    private var amountSortedTransactionsView: some View {
        compactTransactionRows(
            sortedFilteredTransactions,
            showsDate: true
        )
    }

    private func dateHeader(date: Date, transactions: [Transaction]) -> some View {
        let expense = transactions
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        let income = transactions
            .filter { $0.statisticsType == .income }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        return HStack(spacing: HoloSpacing.sm) {
            Text(DetailTabFormatters.dayWeekday.string(from: date))
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)

            Spacer()

            if expense > 0 {
                Text("-\(NumberFormatter.currency.string(from: expense as NSDecimalNumber) ?? "")")
                    .font(.holoLabel)
                    .foregroundColor(.holoToolError)
            }
            if income > 0 {
                Text("+\(NumberFormatter.currency.string(from: income as NSDecimalNumber) ?? "")")
                    .font(.holoLabel)
                    .foregroundColor(.holoSuccess)
            }
        }
        // 水平与行内图标左缘同列（6pt，修旧版 xs 的顶格错位）；上下补一档呼吸
        .padding(.horizontal, 6)
        .padding(.vertical, HoloSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(isSelectedDay(date) ? Color.holoPrimary.opacity(0.08) : Color.clear)
        )
        .id(date)
    }

    private func compactTransactionRows(
        _ transactions: [Transaction],
        showsDate: Bool
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(transactions.renderable) { transaction in
                TransactionRowView(
                    transaction: transaction,
                    isCompact: true,
                    showsDate: showsDate
                ) {
                    editingTransaction = transaction
                }

                if transaction.id != transactions.last?.id {
                    Divider()
                        .background(Color.holoDivider.opacity(0.55))
                        .padding(.leading, 56)
                }
            }
        }
    }

    private func sortedTransactions(_ transactions: [Transaction]) -> [Transaction] {
        transactions.sorted {
            sortOrder.areInIncreasingOrder(sortValue(for: $0), sortValue(for: $1))
        }
    }

    private func isSelectedDay(_ date: Date) -> Bool {
        guard let selectedDate = state.selectedChartDate else { return false }
        return Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }

    // MARK: - 空状态

    private var emptyTransactionState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))

            Text("暂无交易记录")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xxl)
    }
}

// MARK: - Preview

#Preview {
    DetailTabView(state: FinanceAnalysisState())
}
