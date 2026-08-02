//
//  DetailTabView.swift
//  Holo
//
//  明细 Tab 视图
//  包含折线图 + 点击日期后的交易列表
//  支持按粒度下钻显示数据
//

import SwiftUI

// MARK: - DetailTabView

/// 明细 Tab 视图
struct DetailTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    @State private var editingTransaction: Transaction?
    @State private var selectedTrendType: TransactionType = .expense
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

    private var sortedFilteredTransactions: [Transaction] {
        filteredTransactions.sorted {
            sortOrder.areInIncreasingOrder(sortValue(for: $0), sortValue(for: $1))
        }
    }

    private var dailySelectionPoints: [ChartDataPoint] {
        dailyChartDataPoints.filter { point in
            amount(for: point, type: selectedTrendType) > 0
        }
    }

    private var dailyChartDataPoints: [ChartDataPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            calendar.startOfDay(for: tx.date)
        }
        let range = state.currentDateRange
        var current = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)
        var points: [ChartDataPoint] = []

        while current < end {
            let dayTxns = grouped[current] ?? []
            let expense = dayTxns
                .filter { $0.transactionType == .expense }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            let income = dayTxns
                .filter { $0.transactionType == .income }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "M.d"

            points.append(ChartDataPoint(
                date: current,
                label: df.string(from: current),
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
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    trendSection
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                        .padding(.bottom, HoloSpacing.md)

                    transactionListHeader
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.xs)

                    transactionListViewport(
                        height: max(geometry.size.height - 56, 320)
                    )
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.lg)
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.holoBackground)
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in
                state.refresh()
            }
        }
        .onChange(of: selectedTrendType) { _, _ in
            state.selectChartDate(nil)
        }
    }

    private var trendSection: some View {
        VStack(spacing: HoloSpacing.lg) {
            if let category = state.selectedDetailCategory {
                categoryFilterBanner(category)
            }

            LineChartView(
                dataPoints: dailyChartDataPoints,
                selectedDate: state.selectedChartDate,
                displayedType: selectedTrendType,
                displayedTypeSelection: $selectedTrendType,
                selectionDataPoints: dailySelectionPoints,
                onScrubDate: selectChartDateAndScroll,
                onSelectDate: { date in
                    guard let date else {
                        state.selectChartDate(nil)
                        return
                    }
                    selectChartDateAndScroll(date)
                }
            )
        }
    }

    /// 趋势图负责选择日期，明细仍保留全量数据，只改变列表当前可见位置。
    /// 时间定位与金额排序语义冲突时自动回到“时间从新到旧”，避免日期锚点失真。
    private func selectChartDateAndScroll(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard dailySelectionPoints.contains(where: {
            Calendar.current.isDate($0.date, inSameDayAs: day)
        }) else {
            return
        }

        sortOrder = sortOrder.orderForChartNavigation

        state.selectChartDate(day)
        listScrollTarget = day
        listScrollRequestID &+= 1
    }

    private func transactionListViewport(height: CGFloat) -> some View {
        ScrollViewReader { listProxy in
            ScrollView {
                transactionListContent
                    .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .frame(height: height)
            .onChange(of: listScrollRequestID) { _, _ in
                guard let target = listScrollTarget else { return }

                // 排序模式切换与列表重建发生在同一轮更新，下一帧再定位可确保锚点已存在。
                DispatchQueue.main.async {
                    listProxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }

    private func amount(for point: ChartDataPoint, type: TransactionType) -> Decimal {
        switch type {
        case .expense:
            return point.expense
        case .income:
            return point.income
        case .transfer:
            // 转账不参与收支明细图
            return 0
        }
    }

    private func sortValue(for transaction: Transaction) -> FinanceDetailSortValue {
        FinanceDetailSortValue(
            id: transaction.id,
            date: transaction.date,
            amount: transaction.amount.decimalValue
        )
    }

    // MARK: - 选中时间段的交易列表（根据粒度显示）

    private func selectedPeriodTransactionsView(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题栏
            HStack {
                Text(periodTitle(for: date))
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Button {
                    state.selectChartDate(nil)
                } label: {
                    Text("查看全部")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
            }

            // 时间段统计
            periodSummary(for: date)

            // 交易列表
            let periodTransactions = transactionsForPeriod(date)

            if periodTransactions.isEmpty {
                emptyTransactionState
            } else {
                ForEach(periodTransactions, id: \.self) { tx in
                    TransactionRowView(transaction: tx) {
                        editingTransaction = tx
                    }
                }
            }
        }
    }

    // MARK: - 时间段标题

    private func periodTitle(for date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")

        switch state.chartGranularity {
        case .hour:
            df.dateFormat = "M月d日 HH:00"
            return df.string(from: date) + " 时段"

        case .day:
            df.dateFormat = "M月d日"
            return df.string(from: date)

        case .week:
            let weekStart = date.startOfWeek
            guard let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) else {
                return "本周"
            }
            df.dateFormat = "M月d日"
            return "\(df.string(from: weekStart)) - \(df.string(from: weekEnd))"

        case .month:
            df.dateFormat = "yyyy年M月"
            return df.string(from: date)
        }
    }

    // MARK: - 时间段统计

    private func periodSummary(for date: Date) -> some View {
        let periodTxns = transactionsForPeriod(date)
        let expense = periodTxns
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        let income = periodTxns
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        return HStack(spacing: HoloSpacing.lg) {
            HStack(spacing: HoloSpacing.xs) {
                Text("支出")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text(NumberFormatter.currency.string(from: expense as NSDecimalNumber) ?? "¥0")
                    .font(.holoBody)
                    .foregroundColor(.holoError)
            }

            HStack(spacing: HoloSpacing.xs) {
                Text("收入")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text(NumberFormatter.currency.string(from: income as NSDecimalNumber) ?? "¥0")
                    .font(.holoBody)
                    .foregroundColor(.holoSuccess)
            }

            Spacer()

            Text("\(periodTxns.count) 笔")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    // MARK: - 获取时间段内的交易

    private func transactionsForPeriod(_ date: Date) -> [Transaction] {
        let calendar = Calendar.current

        switch state.chartGranularity {
        case .hour:
            // 该小时的交易
            let hourStart = calendar.date(bySettingHour: calendar.component(.hour, from: date), minute: 0, second: 0, of: date) ?? date
            guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return [] }
            return filteredTransactions.filter { tx in
                tx.date >= hourStart && tx.date < hourEnd
            }

        case .day:
            // 该天的交易
            return filteredTransactions.filter { tx in
                calendar.isDate(tx.date, inSameDayAs: date)
            }

        case .week:
            // 该周的交易
            let weekStart = date.startOfWeek
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
            return filteredTransactions.filter { tx in
                tx.date >= weekStart && tx.date < weekEnd
            }

        case .month:
            // 该月的交易
            let monthStart = date.startOfMonth
            guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
            return filteredTransactions.filter { tx in
                tx.date >= monthStart && tx.date < monthEnd
            }
        }
    }

    // MARK: - 分类筛选

    private func categoryFilterBanner(_ category: Category) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            transactionCategoryIcon(category, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(category.name)明细")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Text("\(filteredTransactions.count) 笔 · 当前日期范围")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Button {
                state.selectDetailCategory(nil)
            } label: {
                Text("清除")
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, HoloSpacing.xs)
                    .background(Color.holoPrimary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 全部交易列表

    private var transactionListHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text("交易明细")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Text("\(filteredTransactions.count) 笔")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)

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
        .accessibilityLabel("切换交易明细排序")
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

        return VStack(alignment: .leading, spacing: 10) {
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
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        let income = transactions
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        return HStack(spacing: HoloSpacing.sm) {
            let formatter = DateFormatter()
            Text(formatter.monthDayWeekdayString(from: date))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            if expense > 0 {
                Text("-\(NumberFormatter.currency.string(from: expense as NSDecimalNumber) ?? "")")
                    .font(.system(size: 12))
                    .foregroundColor(.holoError)
            }
            if income > 0 {
                Text("+\(NumberFormatter.currency.string(from: income as NSDecimalNumber) ?? "")")
                    .font(.system(size: 12))
                    .foregroundColor(.holoSuccess)
            }
        }
        .padding(.horizontal, HoloSpacing.xs)
        .padding(.vertical, 2)
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
            ForEach(transactions) { transaction in
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
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无交易记录")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xxl)
    }
}

// MARK: - DateFormatter Extension

private extension DateFormatter {
    func monthDayString(from date: Date) -> String {
        locale = Locale(identifier: "zh_CN")
        dateFormat = "M月d日"
        return string(from: date)
    }

    func monthDayWeekdayString(from date: Date) -> String {
        locale = Locale(identifier: "zh_CN")
        dateFormat = "M月d日 EEEE"
        return string(from: date)
    }
}

// MARK: - Preview

#Preview {
    DetailTabView(state: FinanceAnalysisState())
}
