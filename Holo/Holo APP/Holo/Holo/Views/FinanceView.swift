//
//  FinanceView.swift
//  Holo
//
//  记账功能首页 - 包含底部导航栏（统计/账本/设置）
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI
import UIKit

// MARK: - Finance Tab 枚举

/// 财务模块底部 Tab 枚举
enum FinanceTab: String, CaseIterable {
    case analysis = "统计"
    case ledger = "账本"
    case settings = "设置"
    
    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .analysis: return "chart.pie.fill"
        case .ledger: return "wallet.pass.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - FinanceView

/// 记账功能首页视图（容器）
/// 管理三个子 Tab：统计分析、账本列表、设置
struct FinanceView: View {
    
    // MARK: - Properties
    
    /// 环境变量：dismiss（关闭 fullScreenCover）
    @Environment(\.dismiss) var dismiss
    
    /// 当前选中的 Tab
    @State private var selectedTab: FinanceTab = .ledger
    
    /// 是否显示添加交易页面
    @State private var showAddTransaction: Bool = false
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()
            
            Group {
                switch selectedTab {
                case .analysis:
                    FinanceAnalysisView(onBack: { dismiss() })
                case .ledger:
                    FinanceLedgerView(
                        onBack: { dismiss() },
                        showAddTransaction: $showAddTransaction
                    )
                case .settings:
                    FinanceSettingsView(onBack: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            financeTabBarOnly
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(editingTransaction: nil) {
                // 保存后刷新账本列表（通过 Notification 或 @State 传递）
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        }
    }
    
    // MARK: - 底部 Tab 栏（fixed bottom-0 left-0 w-full，无浮动圆角）
    
    /// 底部导航栏：吸底全宽，中间为「账本」与「+」合一
    private var financeTabBarOnly: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                financeTabButton(.analysis)
                // 中间：在记账页展示 +，在统计/设置页展示账本
                financeCenterTabButton
                financeTabButton(.settings)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, bottomInset)
            .background(
                Color.white
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .background(Color.white.ignoresSafeArea(edges: .bottom))
        .zIndex(40)
    }
    
    /// 中间 Tab：在账本页显示 +（记一笔），在统计/设置页显示账本（切回账本）
    private var financeCenterTabButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedTab == .ledger {
                    showAddTransaction = true
                } else {
                    selectedTab = .ledger
                }
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == .ledger ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)
                
                Group {
                    if selectedTab == .ledger {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.holoPrimary)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: FinanceTab.ledger.icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                
                Text(selectedTab == .ledger ? "记一笔" : "账本")
                    .font(.holoTinyLabel)
                    .fontWeight(selectedTab == .ledger ? .bold : .medium)
                    .foregroundColor(selectedTab == .ledger ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 单个 Tab 按钮（统计 / 设置）
    private func financeTabButton(_ tab: FinanceTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)
                
                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
                
                Text(tab.rawValue)
                    .font(.holoTinyLabel)
                    .fontWeight(selectedTab == tab ? .bold : .medium)
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 圆角辅助（仅指定部分角）

/// 支持只圆化指定角的 Shape
struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// 财务数据发生变化时发送此通知，账本列表监听后刷新
    static let financeDataDidChange = Notification.Name("financeDataDidChange")
}

// MARK: - Finance Ledger View（账本列表 — 原 FinanceView 主体）

/// 账本列表视图（原 FinanceView 的主内容）
struct FinanceLedgerView: View {
    
    // MARK: - Properties
    
    /// 返回回调（关闭 fullScreenCover）
    let onBack: () -> Void
    
    /// 是否显示添加交易（由父视图绑定）
    @Binding var showAddTransaction: Bool
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    // MARK: - State
    
    /// 所有交易记录
    @State private var transactions: [Transaction] = []
    
    /// 正在编辑的交易（nil 表示新增模式）
    @State private var editingTransaction: Transaction? = nil
    
    /// 是否正在加载
    @State private var isLoading: Bool = false
    
    /// 选中的月份
    @State private var selectedMonth: Date = Date()
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏（贴近安全区）
            headerView
            
            // 收支概览卡片
            summaryCards
            
            // 交易记录区域：占满剩余高度并可滚动
            ScrollView {
                transactionListView
                    .padding(.bottom, HoloSpacing.lg)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.holoBackground)
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) {
                Task { await loadTransactions() }
            }
        }
        .task {
            await loadTransactions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            Task { await loadTransactions() }
        }
    }
    
    // MARK: - Header View
    
    /// 顶部导航栏
    private var headerView: some View {
        HStack {
            // 左侧：返回按钮
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.white)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            
            // 中间：日期和标题
            VStack(spacing: 2) {
                Text(formattedDateString)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                
                Text("今日账本")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
            }
            .frame(maxWidth: .infinity)
            
            // 右侧：日历按钮
            Button {
                // TODO: 月份选择器
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 36, height: 36)
                    .background(Color.white)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, 0) // 无多余 pt/mt，日期与标题紧贴灵动岛下方（安全区由系统预留）
        .padding(.bottom, HoloSpacing.md)
        .background(Color.holoBackground)
    }
    
    /// 格式化日期字符串
    private var formattedDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: Date())
    }
    
    // MARK: - Summary Cards
    
    /// 收支概览卡片
    private var summaryCards: some View {
        HStack(spacing: HoloSpacing.md) {
            ExpenseCard(amount: todayExpense)
            IncomeCard(amount: todayIncome)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
    }
    
    /// 今日支出
    private var todayExpense: Decimal {
        todayTransactions
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }
    
    /// 今日收入
    private var todayIncome: Decimal {
        todayTransactions
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }
    
    /// 今日交易
    private var todayTransactions: [Transaction] {
        transactions.filter { Calendar.current.isDateInToday($0.date) }
    }
    
    /// 昨日交易
    private var yesterdayTransactions: [Transaction] {
        transactions.filter { Calendar.current.isDateInYesterday($0.date) }
    }
    
    /// 更早的交易
    private var olderTransactions: [Transaction] {
        transactions.filter {
            !Calendar.current.isDateInToday($0.date) && !Calendar.current.isDateInYesterday($0.date)
        }
    }
    
    // MARK: - Transaction List
    
    /// 交易列表视图
    private var transactionListView: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("交易记录")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                Button {
                    // 查看全部
                } label: {
                    Text("查看全部")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
            
            // 交易列表
            VStack(spacing: HoloSpacing.sm) {
                ForEach(todayTransactions, id: \.self) { transaction in
                    TransactionRowView(transaction: transaction) {
                        editingTransaction = transaction
                    }
                }
                
                if !yesterdayTransactions.isEmpty {
                    DateDivider(title: "昨天")
                    
                    ForEach(yesterdayTransactions, id: \.self) { transaction in
                        TransactionRowView(transaction: transaction) {
                            editingTransaction = transaction
                        }
                    }
                }
                
                if !olderTransactions.isEmpty {
                    DateDivider(title: "更早")
                    
                    ForEach(olderTransactions, id: \.self) { transaction in
                        TransactionRowView(transaction: transaction) {
                            editingTransaction = transaction
                        }
                    }
                }
                
                // 空状态
                if transactions.isEmpty && !isLoading {
                    EmptyStateView()
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
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
}

// MARK: - Finance Analysis View（统计分析 — 占位）

/// 统计分析视图（当前为占位，后续迭代实现）
struct FinanceAnalysisView: View {
    let onBack: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                }
                
                Spacer()
                
                Text("统计分析")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                // 占位保持对称
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, 0)
            .padding(.bottom, HoloSpacing.md)
            
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundColor(.holoPrimary.opacity(0.4))
                
                Text("统计分析")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                
                Text("功能开发中...")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            
            Spacer()
        }
        .background(Color.holoBackground)
    }
}

// MARK: - Finance Settings View（设置 — 占位）

/// 财务设置视图（当前为占位，后续迭代实现）
struct FinanceSettingsView: View {
    let onBack: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                }
                
                Spacer()
                
                Text("设置")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, 0)
            .padding(.bottom, HoloSpacing.md)
            
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundColor(.holoPrimary.opacity(0.4))
                
                Text("设置")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                
                Text("功能开发中...")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            
            Spacer()
        }
        .background(Color.holoBackground)
    }
}

// MARK: - Expense Card

/// 支出卡片
struct ExpenseCard: View {
    let amount: Decimal
    
    var body: some View {
        SummaryCard(
            title: "支出",
            amount: amount,
            iconName: "arrow.down.right",
            iconColor: .holoError,
            iconBgColor: .holoErrorLight,
            decorationColor: .holoErrorLight
        )
    }
}

// MARK: - Income Card

/// 收入卡片
struct IncomeCard: View {
    let amount: Decimal
    
    var body: some View {
        SummaryCard(
            title: "收入",
            amount: amount,
            iconName: "arrow.up.right",
            iconColor: .holoSuccess,
            iconBgColor: .holoSuccessLight,
            decorationColor: .holoSuccessLight
        )
    }
}

// MARK: - Summary Card

/// 收支概览卡片
struct SummaryCard: View {
    let title: String
    let amount: Decimal
    let iconName: String
    let iconColor: Color
    let iconBgColor: Color
    let decorationColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：图标和标题
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(iconBgColor)
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(iconColor)
                }
                
                Text(title)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            
            Spacer()
            
            // 底部：金额（NumberFormatter 已包含 ¥ 前缀，不再手动拼接）
            Text(NumberFormatter.currency.string(from: amount as NSDecimalNumber) ?? "¥0.00")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .padding(HoloSpacing.md)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
        .overlay(
            Circle()
                .fill(decorationColor)
                .frame(width: 80, height: 80)
                .offset(x: 20, y: -20),
            alignment: .topTrailing
        )
        .clipped()
    }
}

// MARK: - Date Divider

/// 日期分隔线
struct DateDivider: View {
    let title: String
    
    var body: some View {
        HStack {
            VStack {
                Divider()
                    .background(Color.holoDivider)
            }
            
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, HoloSpacing.md)
                .background(Color.holoBackground)
            
            VStack {
                Divider()
                    .background(Color.holoDivider)
            }
        }
        .padding(.vertical, HoloSpacing.md)
    }
}

// MARK: - Transaction Row View

/// 交易行视图
struct TransactionRowView: View {
    let transaction: Transaction
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            // 等价 flex justify-between items-center：左侧分类信息，右侧金额严格对齐
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                // 分类图标 + 名称/备注
                categoryIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(transaction.note ?? transaction.category.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    
                    HStack(spacing: HoloSpacing.sm) {
                        Text(transaction.category.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.holoBackground)
                            .clipShape(Capsule())
                        
                        Text(transaction.date, style: .time)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                
                Spacer(minLength: 0)
                
                // 金额：右侧严格对齐，不压缩
                Text(transaction.formattedAmountWithSign)
                    .font(.holoBody)
                    .foregroundColor(transaction.transactionType == .expense ? .holoTextPrimary : .holoSuccess)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(HoloSpacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 分类图标
    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill(transaction.category.swiftUIColor.opacity(0.1))
                .frame(width: 48, height: 48)
            
            transactionCategoryIcon(transaction.category, size: 24)
        }
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
            
            Text("暂无交易记录")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            
            Text("点击 + 按钮记录第一笔交易")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Preview

#Preview {
    FinanceView()
}
