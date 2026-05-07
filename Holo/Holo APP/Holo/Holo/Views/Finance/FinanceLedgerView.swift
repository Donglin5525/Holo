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

    /// 正在复制的交易（nil 表示未在复制）
    @State private var copyingTransaction: Transaction? = nil

    /// 复制目标日期
    @State private var copyTargetDate: Date = Date()

    /// 长按日期快速记账：弹出 Sheet 时使用的预设日期
    @State private var quickAddDate: Date? = nil

    /// 是否显示搜索页
    @State private var showSearch: Bool = false

    /// 预算数据（首页卡片）
    @State private var globalBudgetSummary: GlobalBudgetSummary?
    @State private var categoryWarnings: [CategoryBudgetWarning] = []

    /// 操作完成提示
    @State private var operationMessage: OperationMessage?

    // --- 日期滑动切换 ---

    /// 滑动偏移量（跟随手指 + 切换动画）
    @State private var daySwipeOffset: CGFloat = 0
    /// 是否正在水平滑动（锁定方向，避免与垂直滚动冲突）
    @State private var isDaySwiping: Bool = false
    @State private var daySwipeGestureLock = HorizontalGestureLock()
    
    // --- 月历展开：连续高度控制 ---
    
    /// 已展开高度（0 = 收起，maxCalendarHeight = 完全展开）
    @State private var calendarRevealHeight: CGFloat = 0
    
    /// 拖拽过程中的增量位移
    @State private var dragTranslation: CGFloat = 0
    
    /// 月历完全展开高度
    private let maxCalendarHeight: CGFloat = 280
    
    /// 实时生效高度 = 已锁定 + 拖拽增量，限制在 [0, max]，取整避免亚像素抖动
    private var effectiveCalendarHeight: CGFloat {
        let h = min(max(calendarRevealHeight + dragTranslation, 0), maxCalendarHeight)
        return round(h)
    }

    /// 展开比例 0~1
    private var revealProgress: CGFloat {
        effectiveCalendarHeight / maxCalendarHeight
    }

    /// 周视图固定高度
    private let weekViewHeight: CGFloat = 90

    /// 日历区域总高度（唯一驱动外层布局的值）：90 → 280 线性过渡
    private var calendarAreaHeight: CGFloat {
        weekViewHeight + (maxCalendarHeight - weekViewHeight) * revealProgress
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航（安全区内，避开灵动岛）
            headerView
            
            // 日历区域：ZStack 统一容器，单一高度值驱动外层布局
            ZStack(alignment: .top) {
                // 周视图：仅 opacity 渐隐，不改变高度
                WeekView(calendarState: calendarState)
                    .opacity(Double(1 - revealProgress))

                // 月历：通过高度 + clip 逐步揭示
                ExpandedCalendarView(calendarState: calendarState)
                    .frame(height: effectiveCalendarHeight)
                    .clipped()
                    .allowsHitTesting(effectiveCalendarHeight > 0)
            }
            .frame(height: calendarAreaHeight)
            .clipped()
            
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
                        switch daySwipeGestureLock.update(translation: value.translation) {
                        case .horizontal:
                            isDaySwiping = true
                            daySwipeOffset = value.translation.width * 0.3
                        case .vertical:
                            isDaySwiping = false
                            daySwipeOffset = 0
                        case .undecided:
                            break
                        }
                    }
                    .onEnded { value in
                        guard daySwipeGestureLock.axis == .horizontal else {
                            isDaySwiping = false
                            daySwipeOffset = 0
                            daySwipeGestureLock.reset()
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
                        daySwipeGestureLock.reset()
                    }
            )
            }
            .background(Color.holoCardBackground)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        }
        .background(Color.holoBackground)
        .overlay(alignment: .top) {
            if let operationMessage {
                operationToast(operationMessage)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // --- 弹窗月历（底部抽屉） ---
        .sheet(isPresented: $calendarState.isPopupVisible) {
            PopupCalendarSheet(calendarState: calendarState)
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) {
                calendarState.refreshAfterDataChange()
                showOperationMessage("记账已保存", isError: false)
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
                    showOperationMessage("记账已保存", isError: false)
                }
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            FinanceSearchView()
        }
        // 复制交易日期选择
        .sheet(item: $copyingTransaction) { tx in
            NavigationStack {
                DatePicker(
                    "",
                    selection: $copyTargetDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, HoloSpacing.lg)
                .navigationTitle("复制到")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            copyingTransaction = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            performCopyTransaction(tx, targetDate: copyTargetDate)
                            copyingTransaction = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium])
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

    /// 当前是否展开月历
    private var isCalendarExpanded: Bool {
        calendarRevealHeight > 0
    }

    /// 箭头：点击切换 + 拖拽连续控制
    private var calendarDragHandle: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.holoTextSecondary.opacity(0.45))
            .rotationEffect(.degrees(isCalendarExpanded ? 180 : 0))
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture { toggleCalendarExpand() }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        let rounded = round(v.translation.height)
                        if rounded != dragTranslation { dragTranslation = rounded }
                    }
                    .onEnded { v in
                        let translation = v.translation.height
                        let velocity = v.predictedEndTranslation.height - v.translation.height
                        let target = calendarRevealHeight + translation
                        dragTranslation = 0

                        let shouldExpand: Bool
                        if translation >= 0 {
                            shouldExpand = target > maxCalendarHeight * 0.3 || velocity > 80
                        } else {
                            shouldExpand = target > maxCalendarHeight * 0.55 && velocity > -80
                        }

                        animateCalendarExpand(shouldExpand)
                    }
            )
    }

    /// 点击切换月历展开/收起
    private func toggleCalendarExpand() {
        animateCalendarExpand(!isCalendarExpanded)
    }

    /// 带动画的月历展开/收起
    private func animateCalendarExpand(_ expand: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            calendarRevealHeight = expand ? maxCalendarHeight : 0
        }
        calendarState.expandState = expand ? .expanded : .collapsed
        if !expand {
            calendarState.syncMonthToSelectedDate()
        }
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

                            Button {
                                copyingTransaction = tx
                                copyTargetDate = tx.date
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
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
                await calendarState.refreshData()
                HapticManager.success()
                showOperationMessage("已删除", isError: false)
            } catch {
                print("[FinanceLedger] 删除交易失败: \(error)")
                showOperationMessage("删除失败：\(error.localizedDescription)", isError: true)
            }
            transactionToDelete = nil
        }
    }

    /// 删除整个分期组
    private func deleteInstallmentGroupFromList(_ groupId: UUID) {
        Task {
            do {
                try await FinanceRepository.shared.deleteInstallmentGroup(groupId: groupId)
                await calendarState.refreshData()
                HapticManager.success()
                showOperationMessage("已删除分期", isError: false)
            } catch {
                print("[FinanceLedger] 删除分期组失败: \(error)")
                showOperationMessage("删除失败：\(error.localizedDescription)", isError: true)
            }
            transactionToDelete = nil
        }
    }

    /// 复制交易到指定日期
    private func performCopyTransaction(_ original: Transaction, targetDate: Date) {
        Task {
            do {
                _ = try await FinanceRepository.shared.addTransaction(
                    amount: abs(original.amount.decimalValue),
                    type: original.transactionType,
                    category: original.category,
                    account: original.account,
                    date: targetDate,
                    note: original.note,
                    remark: original.remark,
                    tags: original.tags
                )
                HapticManager.success()
                await calendarState.refreshData()
                showOperationMessage("已复制", isError: false)
            } catch {
                print("[FinanceLedger] 复制交易失败: \(error)")
                showOperationMessage("复制失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func showOperationMessage(_ text: String, isError: Bool) {
        let message = OperationMessage(text: text, isError: isError)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            operationMessage = message
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                guard operationMessage == message else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    operationMessage = nil
                }
            }
        }
    }

    private func operationToast(_ message: OperationMessage) -> some View {
        Label(message.text, systemImage: message.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(message.isError ? .holoError : .holoSuccess)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(message.isError ? Color.holoErrorLight : Color.holoSuccessLight)
                    .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
            )
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

private struct OperationMessage: Equatable {
    let text: String
    let isError: Bool
}
