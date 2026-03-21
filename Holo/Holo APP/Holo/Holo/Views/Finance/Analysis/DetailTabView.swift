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

    var body: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                // 折线图
                LineChartView(
                    dataPoints: state.chartDataPoints,
                    selectedDate: state.selectedChartDate
                ) { date in
                    state.selectChartDate(date)
                }

                // 选中日期的交易列表
                if let selectedDate = state.selectedChartDate {
                    selectedPeriodTransactionsView(selectedDate)
                } else {
                    // 显示全部交易
                    allTransactionsView
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
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
                    TransactionRowView(transaction: tx) {}
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
            return state.transactions.filter { tx in
                tx.date >= hourStart && tx.date < hourEnd
            }

        case .day:
            // 该天的交易
            return state.transactions.filter { tx in
                calendar.isDate(tx.date, inSameDayAs: date)
            }

        case .week:
            // 该周的交易
            let weekStart = date.startOfWeek
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
            return state.transactions.filter { tx in
                tx.date >= weekStart && tx.date < weekEnd
            }

        case .month:
            // 该月的交易
            let monthStart = date.startOfMonth
            guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
            return state.transactions.filter { tx in
                tx.date >= monthStart && tx.date < monthEnd
            }
        }
    }

    // MARK: - 全部交易列表

    private var allTransactionsView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack {
                Text("交易明细")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("\(state.transactions.count) 笔")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 按日期分组
            if state.transactions.isEmpty {
                emptyTransactionState
            } else {
                groupedTransactionsView
            }
        }
    }

    // MARK: - 分组交易列表

    private var groupedTransactionsView: some View {
        let grouped = Dictionary(grouping: state.transactions) { tx in
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

                // 交易列表
                ForEach(grouped[date] ?? [], id: \.self) { tx in
                    TransactionRowView(transaction: tx) {}
                }
            }
        }
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
