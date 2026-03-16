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
/// 支持从左边缘向右滑动返回首页
struct FinanceView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: FinanceTab = .ledger
    @State private var showAddTransaction: Bool = false

    /// 日历状态提升到此层级，避免切换 Tab 时被销毁
    @StateObject private var calendarState = CalendarState()

    /// 右滑返回偏移量
    @State private var swipeBackOffset: CGFloat = 0
    
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
                        calendarState: calendarState,
                        onBack: { dismiss() },
                        showAddTransaction: $showAddTransaction
                    )
                case .settings:
                    FinanceSettingsView(onBack: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .offset(x: swipeBackOffset)
        .gesture(
            DragGesture()
                .onChanged { v in
                    // 仅在从左侧 40pt 范围内起始的右滑手势生效
                    if v.startLocation.x < 40 && v.translation.width > 0 {
                        swipeBackOffset = v.translation.width
                    }
                }
                .onEnded { v in
                    if v.startLocation.x < 40 && v.translation.width > 120 {
                        withAnimation(.easeOut(duration: 0.25)) {
                            swipeBackOffset = UIScreen.main.bounds.width
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dismiss() }
                    } else {
                        withAnimation(.spring(response: 0.3)) { swipeBackOffset = 0 }
                    }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            financeTabBarOnly
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(editingTransaction: nil) {
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

// MARK: - Finance Ledger View（集成周视图 + 月历 + 弹窗月历 + 按日筛选）

/// 账本列表视图（集成日历组件）
/// 修复：① 日历 icon 弹出底部抽屉  ② 展开月历时隐藏周视图
///       ③ 安全区避开灵动岛  ④ 单日期标题  ⑤ 返回按钮 + 手势
struct FinanceLedgerView: View {

    // MARK: - Properties

    /// 日历状态（由父视图持有，切换 Tab 时不丢失）
    @ObservedObject var calendarState: CalendarState

    let onBack: () -> Void
    @Binding var showAddTransaction: Bool
    
    /// 正在编辑的交易
    @State private var editingTransaction: Transaction? = nil
    
    /// 待删除的交易（滑动删除确认用）
    @State private var transactionToDelete: Transaction? = nil

    /// 是否显示分期删除选项
    @State private var showInstallmentDeleteOptions: Bool = false
    
    /// 长按日期快速记账：弹出 Sheet 时使用的预设日期
    @State private var quickAddDate: Date? = nil

    /// 是否显示搜索页
    @State private var showSearch: Bool = false
    
    // --- 月历展开：连续高度控制 ---
    
    /// 已展开高度（0 = 收起，maxCalendarHeight = 完全展开）
    @State private var calendarRevealHeight: CGFloat = 0
    
    /// 拖拽过程中的增量位移
    @State private var dragTranslation: CGFloat = 0
    
    /// 月历完全展开高度
    private let maxCalendarHeight: CGFloat = 300
    
    /// 实时生效高度 = 已锁定 + 拖拽增量，限制在 [0, max]
    private var effectiveCalendarHeight: CGFloat {
        min(max(calendarRevealHeight + dragTranslation, 0), maxCalendarHeight)
    }
    
    /// 展开比例 0~1
    private var revealProgress: CGFloat {
        effectiveCalendarHeight / maxCalendarHeight
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航（安全区内，避开灵动岛）
            headerView
            
            // 周视图（展开月历时渐隐 + 高度收缩）
            // 容器高度 = 星期标题(16) + 间距(6) + 格子(56) + 内边距(8) ≈ 90
            WeekView(calendarState: calendarState)
                .opacity(Double(1 - revealProgress))
                .frame(height: max(0, 90 * (1 - revealProgress)))
                .clipped()
            
            // 月历区域：通过高度 + clip 控制可见区域
            // allowsHitTesting: 高度为 0 时禁止触摸，防止点击周视图误触隐藏的月历格子
            ExpandedCalendarView(calendarState: calendarState)
                .frame(height: effectiveCalendarHeight)
                .clipped()
                .allowsHitTesting(effectiveCalendarHeight > 0)
            
            // 拖拽手柄
            calendarDragHandle
            
            // 收支概览
            summaryCards
            
            // 交易列表
            ScrollView {
                transactionListView
                    .padding(.bottom, HoloSpacing.lg)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.holoBackground)
        // --- 弹窗月历（底部抽屉） ---
        .sheet(isPresented: $calendarState.isPopupVisible) {
            PopupCalendarSheet(calendarState: calendarState)
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) {
                calendarState.refreshAfterDataChange()
            }
        }
        // 长按日期快速记账 Sheet
        .sheet(isPresented: Binding(
            get: { quickAddDate != nil },
            set: { if !$0 { quickAddDate = nil } }
        )) {
            if let date = quickAddDate {
                AddTransactionSheet(editingTransaction: nil, presetDate: date) {
                    calendarState.refreshAfterDataChange()
                }
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            FinanceSearchView()
        }
        .task { await calendarState.initialLoad() }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            calendarState.refreshAfterDataChange()
        }
        // 监听长按日期事件，触发快速记账 Sheet
        .onChange(of: calendarState.longPressDate) { _, newDate in
            if let date = newDate {
                calendarState.selectDate(date)
                quickAddDate = date
                calendarState.longPressDate = nil
            }
        }
    }
    
    // MARK: - 顶部导航栏
    
    /// 修复 #3（安全区）#4（单日期）#5（返回按钮）
    private var headerView: some View {
        HStack {
            // 返回按钮（确保可点击区域足够大）
            Button(action: { onBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.white)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            
            Spacer()
            
            // 仅保留一个标题（修复 #4：去掉小日期文字）
            Text(headerTitle)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            
            Spacer()
            
            HStack(spacing: 8) {
                // 搜索按钮
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                }

                // 「返回今天」按钮 — 仅在选中日期非今天时显示
                if !calendarState.selectedDate.isToday {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            calendarState.goToToday()
                        }
                    } label: {
                        Text("今")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 40, height: 40)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                
                // 日历 icon → 弹出底部抽屉
                Button(action: { calendarState.showPopupCalendar() }) {
                    Image(systemName: "calendar")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(calendarState.isPopupVisible ? .holoPrimary : .holoTextSecondary)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                }
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.holoBackground)
    }
    
    /// 标题：今天显示"今日账本"，其他日期仅显示"M月d日"
    private var headerTitle: String {
        if calendarState.selectedDate.isToday { return "今日账本" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return f.string(from: calendarState.selectedDate)
    }
    
    // MARK: - 拖拽手柄（控制月历展开/收起）
    
    /// 修复 #2：下拉手柄连续控制月历高度
    private var calendarDragHandle: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.holoTextSecondary.opacity(0.25))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in dragTranslation = v.translation.height }
                .onEnded { v in
                    let target = calendarRevealHeight + v.translation.height
                    let velocity = v.predictedEndTranslation.height - v.translation.height
                    dragTranslation = 0
                    // 根据位置和速度判断展开/收起
                    let shouldExpand = target > maxCalendarHeight * 0.35 || velocity > 100
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        calendarRevealHeight = shouldExpand ? maxCalendarHeight : 0
                    }
                    calendarState.expandState = shouldExpand ? .expanded : .collapsed
                    // 收起时：将 currentMonth 同步回 selectedDate 所在月，避免周视图和月状态不一致
                    if !shouldExpand {
                        calendarState.syncMonthToSelectedDate()
                    }
                }
        )
    }
    
    // MARK: - 收支概览卡片
    
    private var summaryCards: some View {
        HStack(spacing: HoloSpacing.md) {
            ExpenseCard(amount: calendarState.selectedDayExpense)
            IncomeCard(amount: calendarState.selectedDayIncome)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
    }
    
    // MARK: - 交易列表（按选中日期）
    
    private var transactionListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("交易记录")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.md)
            
            VStack(spacing: HoloSpacing.sm) {
                ForEach(calendarState.selectedDayTransactions, id: \.self) { tx in
                    TransactionRowView(transaction: tx) { editingTransaction = tx }
                        .contextMenu {
                            Button {
                                editingTransaction = tx
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            
                            Button(role: .destructive) {
                                transactionToDelete = tx
                                if tx.isInstallment {
                                    showInstallmentDeleteOptions = true
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
                
                if calendarState.selectedDayTransactions.isEmpty && !calendarState.isLoading {
                    EmptyStateView()
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
        }
        // 普通交易删除确认
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { transactionToDelete != nil && !showInstallmentDeleteOptions },
                set: { if !$0 { transactionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除这笔交易", role: .destructive) {
                if let tx = transactionToDelete {
                    deleteTransactionFromList(tx)
                }
            }
            Button("取消", role: .cancel) {
                transactionToDelete = nil
            }
        } message: {
            Text("删除后无法恢复，确定要删除吗？")
        }
        // 分期交易删除选项
        .confirmationDialog(
            "删除分期交易",
            isPresented: $showInstallmentDeleteOptions,
            titleVisibility: .visible
        ) {
            Button("仅删除此期", role: .destructive) {
                if let tx = transactionToDelete {
                    deleteTransactionFromList(tx)
                }
            }
            Button("删除全部分期", role: .destructive) {
                if let tx = transactionToDelete, let groupId = tx.installmentGroupId {
                    deleteInstallmentGroupFromList(groupId)
                }
            }
            Button("取消", role: .cancel) {
                transactionToDelete = nil
            }
        } message: {
            if let tx = transactionToDelete {
                Text("这是一笔分期交易（\(tx.installmentLabel ?? "")），请选择删除方式")
            }
        }
    }
    
    /// 从列表直接删除交易
    private func deleteTransactionFromList(_ transaction: Transaction) {
        Task {
            do {
                try await FinanceRepository.shared.deleteTransaction(transaction)
                calendarState.refreshAfterDataChange()
            } catch {
                print("[FinanceLedger] 删除交易失败: \(error)")
            }
            transactionToDelete = nil
        }
    }

    /// 删除整个分期组
    private func deleteInstallmentGroupFromList(_ groupId: UUID) {
        Task {
            do {
                try await FinanceRepository.shared.deleteInstallmentGroup(groupId: groupId)
                calendarState.refreshAfterDataChange()
            } catch {
                print("[FinanceLedger] 删除分期组失败: \(error)")
            }
            transactionToDelete = nil
        }
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

// MARK: - Finance Settings View

/// 财务设置视图 — 包含数据导入导出等功能
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
            
            ScrollView {
                VStack(spacing: HoloSpacing.xl) {
                    // 数据导入导出模块
                    ImportExportView()
                }
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .background(Color.holoBackground)
    }
}

// MARK: - Expense Card

/// 支出卡片（去边框 / 微观渐变 / 负空间 / 毛玻璃）
struct ExpenseCard: View {
    let amount: Decimal
    
    var body: some View {
        SummaryCard(
            title: "支出",
            amount: amount,
            iconName: "arrow.down.right",
            iconColor: .holoError,
            gradientStart: Color.holoErrorLight.opacity(0.5),
            gradientEnd: Color.white.opacity(0.2),
            strokeColor: Color.holoError.opacity(0.12)
        )
    }
}

// MARK: - Income Card

/// 收入卡片（去边框 / 微观渐变 / 负空间 / 毛玻璃）
struct IncomeCard: View {
    let amount: Decimal
    
    var body: some View {
        SummaryCard(
            title: "收入",
            amount: amount,
            iconName: "arrow.up.right",
            iconColor: .holoSuccess,
            gradientStart: Color.holoSuccessLight.opacity(0.5),
            gradientEnd: Color.white.opacity(0.2),
            strokeColor: Color.holoSuccess.opacity(0.12)
        )
    }
}

// MARK: - Summary Card

/// 收支概览卡片
/// 设计原则：去边框化、微观渐变、负空间平衡、毛玻璃
struct SummaryCard: View {
    let title: String
    let amount: Decimal
    let iconName: String
    let iconColor: Color
    let gradientStart: Color
    let gradientEnd: Color
    let strokeColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图标 + 标题，留白充足
            HStack(spacing: HoloSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(iconColor)
                }
                Text(title)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            
            Spacer(minLength: 16)
            
            // 金额，留白呼吸
            Text(NumberFormatter.currency.string(from: amount as NSDecimalNumber) ?? "¥0.00")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 136)
        .padding(HoloSpacing.lg) // 负空间：更大内边距
        .background {
            ZStack {
                // 毛玻璃：半透明模糊层增加深度
                Rectangle()
                    .fill(.ultraThinMaterial)
                // 微观渐变：浅色系薄层叠在毛玻璃上，不盖住模糊
                LinearGradient(
                    colors: [gradientStart, gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .stroke(strokeColor, lineWidth: 0.5) // 0.5px 半透明描边，去厚重边框
        )
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

                        // 分期标签
                        if let label = transaction.installmentLabel {
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.holoPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.holoPrimary.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Text(transaction.date, style: .time)
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                
                Spacer(minLength: 0)
                
                // 金额：右侧严格对齐，不压缩（不显示正负号，类型通过颜色区分）
                Text(transaction.formattedAmount)
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
