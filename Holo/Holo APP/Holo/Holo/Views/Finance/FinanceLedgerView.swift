//
//  FinanceLedgerView.swift
//  Holo
//
//  财务账本视图
//

import SwiftUI

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

    /// 预算数据（首页卡片）
    @State private var globalBudgetSummary: GlobalBudgetSummary?
    @State private var categoryWarnings: [CategoryBudgetWarning] = []

    // --- 日期滑动切换 ---

    /// 滑动偏移量（跟随手指 + 切换动画）
    @State private var daySwipeOffset: CGFloat = 0
    /// 是否正在水平滑动（锁定方向，避免与垂直滚动冲突）
    @State private var isDaySwiping: Bool = false
    
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
            
            // ===== Bottom Sheet 容器 =====
            VStack(spacing: 0) {
                // 拖拽手柄
                calendarDragHandle
            
            // 收支概览
            summaryCards

            // 预算总览卡片
            if let summary = globalBudgetSummary {
                BudgetSummaryCard(summary: summary, warnings: categoryWarnings)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // 交易列表（支持左右滑动切换日期）
            ScrollView(showsIndicators: false) {
                transactionListView
                    .padding(.bottom, HoloSpacing.lg)
                    .allowsHitTesting(!isDaySwiping) // 滑动中禁止点击账单
            }
            .scrollDisabled(isDaySwiping) // 水平滑动时锁定垂直滚动
            .frame(maxHeight: .infinity)
            .offset(x: daySwipeOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        let h = abs(value.translation.width)
                        let v = abs(value.translation.height)

                        if !isDaySwiping {
                            // 严格要求水平位移 > 1.5 倍垂直位移才锁定为日滑动
                            guard h > 10 && h > v * 1.5 else { return }
                            isDaySwiping = true
                        }

                        if isDaySwiping {
                            daySwipeOffset = value.translation.width * 0.3
                        }
                    }
                    .onEnded { value in
                        guard isDaySwiping else {
                            daySwipeOffset = 0
                            return
                        }

                        let threshold: CGFloat = 50
                        if value.translation.width < -threshold {
                            performDaySwipe(forward: true)
                        } else if value.translation.width > threshold {
                            performDaySwipe(forward: false)
                        } else {
                            withAnimation(.spring(response: 0.3)) { daySwipeOffset = 0 }
                            isDaySwiping = false
                        }
                    }
            )
            }
            .background(Color.holoCardBackground)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
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
        .task {
            await calendarState.initialLoad()
            loadBudgetData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            calendarState.refreshAfterDataChange()
            loadBudgetData()
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
        VStack(spacing: 0) {
            // Row 1: 返回按钮 | Spacer | 搜索 + 日历按钮
            HStack {
                Button(action: { onBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                }

                Spacer()

                HStack(spacing: 8) {
                    // 搜索按钮
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, height: 40)
                            .background(Color.holoCardBackground)
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
                            .background(Color.holoCardBackground)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Row 2: 标题居中（不受左右按钮宽度影响）
            Text(headerTitle)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
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
                .fill(Color.holoTextSecondary.opacity(0.3))
                .frame(width: 36, height: 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
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
    
    // MARK: - 月度收支概览卡片

    private var summaryCards: some View {
        @ObservedObject var displaySettings = FinanceDisplaySettings.shared

        let showExpense = displaySettings.showMonthlyExpense
        let showIncome = displaySettings.showMonthlyIncome

        return Group {
            if showExpense && showIncome {
                HStack(spacing: HoloSpacing.sm) {
                    monthlyCard("本月支出", amount: calendarState.currentMonthExpense,
                                previous: calendarState.previousPeriodExpense,
                                icon: "arrow.down.right", color: .holoError,
                                compact: true)
                    monthlyCard("本月收入", amount: calendarState.currentMonthIncome,
                                previous: calendarState.previousPeriodIncome,
                                icon: "arrow.up.right", color: .holoSuccess,
                                compact: true)
                }
            } else if showExpense {
                monthlyCard("本月支出", amount: calendarState.currentMonthExpense,
                            previous: calendarState.previousPeriodExpense,
                            icon: "arrow.down.right", color: .holoError,
                            compact: false,
                            todayAmount: calendarState.selectedDayExpense)
            } else if showIncome {
                monthlyCard("本月收入", amount: calendarState.currentMonthIncome,
                            previous: calendarState.previousPeriodIncome,
                            icon: "arrow.up.right", color: .holoSuccess,
                            compact: false,
                            todayAmount: calendarState.selectedDayIncome)
            }
        }
        .padding(.horizontal, 14)
    }

    /// 构建月度卡片，减少重复代码
    private func monthlyCard(_ title: String, amount: Decimal, previous: Decimal?,
                             icon: String, color: Color, compact: Bool,
                             todayAmount: Decimal? = nil) -> some View {
        MonthlySummaryCard(
            title: title,
            amount: amount,
            previousAmount: previous,
            iconName: icon,
            iconColor: color,
            isCompact: compact,
            todayAmount: todayAmount
        )
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
            .padding(.top, 24)
            .padding(.bottom, HoloSpacing.xs)
            
            VStack(spacing: 0) {
                ForEach(Array(calendarState.selectedDayTransactions.enumerated()), id: \.element) { index, tx in
                    TransactionRowView(transaction: tx) {
                        // 滑动切换日期中，忽略点击（防止误触进入编辑页）
                        guard !isDaySwiping && daySwipeOffset == 0 else { return }
                        editingTransaction = tx
                    }
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

    // MARK: - 日期滑动切换（两阶段动画，复用 WeekView 模式）

    /// 执行日期切换动画
    /// - Parameter forward: true = 左滑 → 后一天，false = 右滑 → 前一天
    private func performDaySwipe(forward: Bool) {
        // 阶段1: 快速滑出
        let slideOut: CGFloat = forward
            ? -UIScreen.main.bounds.width * 0.3
            : UIScreen.main.bounds.width * 0.3

        withAnimation(.easeOut(duration: 0.15)) {
            daySwipeOffset = slideOut
        }

        // 阶段2: 更新数据 + 弹入新一天
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let newDate = Calendar.current.date(
                byAdding: .day,
                value: forward ? 1 : -1,
                to: calendarState.selectedDate
            ) {
                calendarState.selectDate(newDate)
            }

            // 瞬移到对侧，然后弹入
            daySwipeOffset = -slideOut
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                daySwipeOffset = 0
            }

            isDaySwiping = false
        }
    }

    // MARK: - Budget Data

    /// 加载预算数据（首页卡片）
    private func loadBudgetData() {
        globalBudgetSummary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
        categoryWarnings = BudgetRepository.shared.getWarningCategoryBudgets(period: .month)
    }
}
