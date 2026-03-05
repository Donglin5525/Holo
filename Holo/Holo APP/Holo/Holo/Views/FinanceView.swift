//
//  FinanceView.swift
//  Holo
//
//  记账功能首页 - 交易列表视图
//  显示所有交易记录，支持添加、编辑、删除操作
//

import SwiftUI

/// 记账功能首页视图
struct FinanceView: View {
    
    // MARK: - Properties
    
    /// 环境变量：dismiss
    @Environment(\.dismiss) var dismiss
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    // MARK: - State
    
    /// 所有交易记录
    @State private var transactions: [Transaction] = []
    
    /// 是否显示添加交易页面
    @State private var showAddTransaction: Bool = false
    
    /// 是否正在加载
    @State private var isLoading: Bool = false
    
    /// 选中的月份
    @State private var selectedMonth: Date = Date()
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty && !isLoading {
                    // 空状态
                    EmptyStateView()
                } else {
                    // 交易列表
                    transactionList
                }
            }
            .navigationTitle("记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("返回")
                                .font(.holoLabel)
                        }
                        .foregroundColor(.holoTextPrimary)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddTransaction = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .background(Color.holoBackground)
            .sheet(isPresented: $showAddTransaction) {
                AddTransactionView()
            }
            .onChange(of: showAddTransaction) { _, isShowing in
                // 关闭添加记账 sheet 后重新加载列表，使刚保存的记录立即显示
                if !isShowing {
                    Task { await loadTransactions() }
                }
            }
            .task {
                await loadTransactions()
            }
        }
    }
    
    // MARK: - Transaction List
    
    /// 交易列表
    private var transactionList: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                // 月度概览
                MonthSummaryView(
                    transactions: transactions,
                    month: selectedMonth
                )
                .padding(.horizontal, HoloSpacing.lg)
                
                // 交易列表
                VStack(spacing: 0) {
                    ForEach(groupTransactionsByDate(transactions), id: \.key) { date, transactions in
                        TransactionSection(
                            date: date,
                            transactions: transactions
                        )
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
            }
            .padding(.vertical, HoloSpacing.lg)
        }
    }
    
    // MARK: - Methods
    
    /// 加载交易记录
    @MainActor
    private func loadTransactions() async {
        isLoading = true
        
        do {
            transactions = try await repository.getTransactions(for: selectedMonth)
        } catch {
            print("加载交易记录失败：\(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    /// 按日期分组交易记录
    private func groupTransactionsByDate(_ transactions: [Transaction]) -> [(key: Date, value: [Transaction])] {
        let grouped = Dictionary(grouping: transactions) { transaction -> Date in
            Calendar.current.startOfDay(for: transaction.date)
        }
        
        return grouped.sorted { $0.key > $1.key }
    }
}

// MARK: - Month Summary View

/// 月度概览视图
struct MonthSummaryView: View {
    
    // MARK: - Properties
    
    /// 交易记录
    let transactions: [Transaction]
    
    /// 月份
    let month: Date
    
    // MARK: - Computed Properties
    
    /// 总支出
    private var totalExpense: Decimal {
        transactions
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }
    
    /// 总收入
    private var totalIncome: Decimal {
        transactions
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }
    
    /// 格式化月份
    private var formattedMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 MM 月"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: month)
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            // 月份标题
            Text(formattedMonth)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            
            // 收支概览
            HStack(spacing: HoloSpacing.lg) {
                // 支出
                VStack(spacing: 4) {
                    Text("支出")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    
                    Text(NumberFormatter.currency.string(from: totalExpense as NSDecimalNumber) ?? "0.00")
                        .font(.holoHeading)
                        .foregroundColor(.holoPrimary)
                }
                
                Divider()
                    .frame(height: 40)
                
                // 收入
                VStack(spacing: 4) {
                    Text("收入")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    
                    Text(NumberFormatter.currency.string(from: totalIncome as NSDecimalNumber) ?? "0.00")
                        .font(.holoHeading)
                        .foregroundColor(.holoSuccess)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )
            )
        }
        .padding(HoloSpacing.md)
    }
}

// MARK: - Transaction Section

/// 交易分组
struct TransactionSection: View {
    
    // MARK: - Properties
    
    /// 日期
    let date: Date
    
    /// 交易记录
    let transactions: [Transaction]
    
    // MARK: - Computed Properties
    
    /// 格式化日期标题
    private var dateTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM 月 dd 日 EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.string(from: date)
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 日期标题
            Text(dateTitle)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .padding(.vertical, HoloSpacing.sm)
            
            // 交易列表
            VStack(spacing: HoloSpacing.sm) {
                ForEach(transactions, id: \.self) { transaction in
                    TransactionRow(transaction: transaction)
                }
            }
        }
    }
}

// MARK: - Transaction Row

/// 交易记录行
struct TransactionRow: View {
    
    // MARK: - Properties
    
    /// 交易记录
    let transaction: Transaction
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            // 分类图标
            ZStack {
                Circle()
                    .fill(transaction.category.swiftUIColor.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                Image(systemName: transaction.category.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(transaction.category.swiftUIColor)
            }
            
            // 交易信息
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                
                if let note = transaction.note {
                    Text(note)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            
            Spacer()
            
            // 金额
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.formattedAmountWithSign)
                    .font(.holoBody)
                    .foregroundColor(
                        transaction.transactionType == .expense
                            ? .holoPrimary
                            : .holoSuccess
                    )
                
                Text(transaction.account.name)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Empty State View

/// 空状态视图
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))
            
            Text("还没有交易记录")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            
            Text("点击右上角添加第一笔记账")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
    }
}

// MARK: - Preview

#Preview {
    FinanceView()
}
