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

    private var filteredTransactions: [Transaction] {
        guard let category = state.selectedDetailCategory else {
            return state.transactions
        }
        return state.transactions.filter {
            state.transaction($0, matchesDetailCategory: category)
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
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                fixedTrendSection(scrollProxy: scrollProxy)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.md)

                transactionListHeader
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.sm)

                ScrollView {
                    transactionListContent
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.bottom, HoloSpacing.lg)
                }
            }
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

    private func fixedTrendSection(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            if let category = state.selectedDetailCategory {
                categoryFilterBanner(category)
            }

            LineChartView(
                dataPoints: dailyChartDataPoints,
                selectedDate: state.selectedChartDate,
                displayedType: selectedTrendType,
                displayedTypeSelection: $selectedTrendType,
                selectionDataPoints: dailySelectionPoints
            ) { date in
                guard let date else {
                    state.selectChartDate(nil)
                    return
                }

                let day = Calendar.current.startOfDay(for: date)
                guard dailySelectionPoints.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) else {
                    return
                }

                state.selectChartDate(day)
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollProxy.scrollTo(day, anchor: .top)
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
        }
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
        HStack {
            Text("交易明细")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Text("\(filteredTransactions.count) 笔")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    @ViewBuilder
    private var transactionListContent: some View {
        if filteredTransactions.isEmpty {
            emptyTransactionState
        } else {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                groupedTransactionsView
            }
        }
    }

    private var allTransactionsView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            transactionListHeader

            // 按日期分组
            transactionListContent
        }
    }

    // MARK: - 分组交易列表

    private var groupedTransactionsView: some View {
        let grouped = Dictionary(grouping: filteredTransactions) { tx in
            Calendar.current.startOfDay(for: tx.date)
        }

        return ForEach(
            grouped.keys.sorted(by: >),
            id: \.self
        ) { date in
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                // 日期标题
                HStack {
                    let df = DateFormatter()
                    Text(df.monthDayWeekdayString(from: date))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    // 日汇总
                    let dayTxns = grouped[date] ?? []
                    let expense = dayTxns
                        .filter { $0.transactionType == .expense }
                        .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
                    let income = dayTxns
                        .filter { $0.transactionType == .income }
                        .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

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

                // 交易列表
                ForEach(grouped[date] ?? [], id: \.self) { tx in
                    TransactionRowView(transaction: tx) {
                        editingTransaction = tx
                    }
                }
            }
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
