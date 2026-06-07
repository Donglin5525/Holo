//
//  CategoryDetailSheet.swift
//  Holo
//
//  分类交易明细弹窗：展示某分类下的具体交易列表
//  按日期分组，复用 TransactionRowView
//

import SwiftUI

// MARK: - CategoryDetailSheet

/// 分类交易明细弹窗
struct CategoryDetailSheet: View {
    let category: Category
    let transactions: [Transaction]

    @Environment(\.dismiss) private var dismiss
    @State private var editingTransaction: Transaction?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    headerCard
                    transactionList
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: HoloSpacing.md) {
            transactionCategoryIcon(category, size: 48)

            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(category.name)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: HoloSpacing.md) {
                    Label {
                        Text(totalFormattedAmount)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    } icon: {
                        Image(systemName: "yensign.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Label {
                        Text("\(transactions.count) 笔")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    } icon: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }

            Spacer()
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Transaction List

    private var transactionList: some View {
        Group {
            if transactions.isEmpty {
                emptyState
            } else {
                groupedTransactionView
            }
        }
    }

    private var groupedTransactionView: some View {
        let grouped = Dictionary(grouping: transactions) { tx in
            Calendar.current.startOfDay(for: tx.date)
        }

        return VStack(spacing: HoloSpacing.lg) {
            ForEach(
                grouped.keys.sorted(by: >),
                id: \.self
            ) { date in
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    // 日期标题 + 日汇总
                    dateHeader(date: date, transactions: grouped[date] ?? [])

                    // 交易列表
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

    private func dateHeader(date: Date, transactions dayTxns: [Transaction]) -> some View {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 EEEE"
        let dateString = df.string(from: date)
        let expense = dayTxns
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        let income = dayTxns
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        return HStack {
            Text(dateString)
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无交易记录")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
    }

    // MARK: - Computed

    private var totalFormattedAmount: String {
        let total = transactions.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        return NumberFormatter.compactCurrency(total)
    }
}
