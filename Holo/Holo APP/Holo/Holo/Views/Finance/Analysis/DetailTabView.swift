//
//  DetailTabView.swift
//  Holo
//
//  明细 Tab 视图
//  包含折线图 + 点击日期后的交易列表
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
                    selectedDateTransactionsView(selectedDate)
                } else {
                    // 显示全部交易
                    allTransactionsView
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
    }

    // MARK: - 选中日期的交易列表

    private func selectedDateTransactionsView(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题栏
            HStack {
                let df = DateFormatter()
                Text(df.monthDayString(from: date))
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

            // 交易列表
            let dayTransactions = state.transactions.filter { tx in
                Calendar.current.isDate(tx.date, inSameDayAs: date)
            }

            if dayTransactions.isEmpty {
                emptyTransactionState
            } else {
                ForEach(dayTransactions, id: \.self) { tx in
                    TransactionRowView(transaction: tx) {}
                }
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
                let df = DateFormatter()
                HStack {
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
