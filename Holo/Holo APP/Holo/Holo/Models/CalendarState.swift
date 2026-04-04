//
//  CalendarState.swift
//  Holo
//
//  日历模块的 ViewModel — 管理日期选择、月份切换、
//  弹窗展开收起、每日汇总缓存、交易列表加载
//

import SwiftUI
import Combine

// MARK: - 展开状态枚举

/// 月历展开状态
enum CalendarExpandState {
    case collapsed
    case expanded
}

// MARK: - CalendarState

/// 日历组件统一状态管理器（所有视图共享同一实例）
@MainActor
class CalendarState: ObservableObject {
    
    // MARK: - 对外发布属性
    
    /// 当前选中日期
    @Published var selectedDate: Date = Date()
    
    /// 当前展示的月份
    @Published var currentMonth: Date = Date().startOfMonth
    
    /// 当前周起始日（周一）
    @Published var currentWeekStart: Date = Date().startOfWeek
    
    /// 展开/收起状态（下拉 + 弹窗共享）
    @Published var expandState: CalendarExpandState = .collapsed
    
    /// 弹窗月历是否显示
    @Published var isPopupVisible: Bool = false
    
    /// 长按日期快速记账 — 触发后设置此值，外部监听弹出 AddTransactionSheet
    @Published var longPressDate: Date? = nil
    
    /// 月度每日汇总
    @Published var dailySummaries: [Date: DailySummary] = [:]
    
    /// 选中日期的交易列表
    @Published var selectedDayTransactions: [Transaction] = []
    
    /// 选中日期支出/收入
    @Published var selectedDayExpense: Decimal = 0
    @Published var selectedDayIncome: Decimal = 0

    /// 本月支出/收入总计
    @Published var currentMonthExpense: Decimal = 0
    @Published var currentMonthIncome: Decimal = 0

    /// 上月同期对比值（nil 表示无数据）
    @Published var previousPeriodExpense: Decimal? = nil
    @Published var previousPeriodIncome: Decimal? = nil

    /// 加载状态
    @Published var isLoading: Bool = false
    
    // MARK: - 私有
    
    /// 缓存：key = 月首日，value = 月度 DailySummary
    private var summaryCache: [Date: [Date: DailySummary]] = [:]
    private let repository = FinanceRepository.shared
    
    // MARK: - 日期操作
    
    /// 选中某一天（自动加载交易数据）
    func selectDate(_ date: Date) {
        selectedDate = date
        currentWeekStart = date.startOfWeek
        if !date.isSameMonth(as: currentMonth) {
            currentMonth = date.startOfMonth
        }
        Task { await loadSelectedDayData() }
    }
    
    func goToNextMonth() { currentMonth = currentMonth.addingMonths(1); loadMonthIfNeeded() }
    func goToPreviousMonth() { currentMonth = currentMonth.addingMonths(-1); loadMonthIfNeeded() }
    
    /// 跳转到指定年月（年月滚轮选择器确认后调用）
    func jumpToMonth(year: Int, month: Int) {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let target = Calendar.current.date(from: comps) else { return }
        currentMonth = target.startOfMonth
        // 选中该月第一天（如果是当前月则选中今天）
        if Date().isSameMonth(as: target) {
            selectDate(Date())
        } else {
            selectDate(target)
        }
    }
    
    func goToNextWeek() {
        currentWeekStart = currentWeekStart.addingWeeks(1)
        selectDate(currentWeekStart)
    }
    func goToPreviousWeek() {
        currentWeekStart = currentWeekStart.addingWeeks(-1)
        selectDate(currentWeekStart)
    }
    
    func goToToday() { selectDate(Date()) }

    /// 将 currentMonth 同步回 selectedDate 所在月（月历收起时调用，防止月/周不一致）
    func syncMonthToSelectedDate() {
        let target = selectedDate.startOfMonth
        if currentMonth != target {
            currentMonth = target
            Task { await loadMonthSummaries(for: currentMonth) }
        }
    }
    
    // MARK: - 展开控制
    
    func toggleExpand() { expandState = expandState == .collapsed ? .expanded : .collapsed }
    func expand() { expandState = .expanded }
    func collapse() { expandState = .collapsed }
    
    // MARK: - 弹窗控制
    
    /// 打开弹窗月历
    func showPopupCalendar() { isPopupVisible = true }
    
    /// 关闭弹窗（withSelection: true 表示应用选中日期）
    func dismissPopupCalendar(withSelection: Bool = false) { isPopupVisible = false }
    
    // MARK: - 数据加载
    
    /// 首次加载：当月汇总 + 当日交易 + 月度汇总 + 环比
    func initialLoad() async {
        isLoading = true
        await loadMonthSummaries(for: currentMonth)
        await loadSelectedDayData()
        loadMonthlySummary()
        await loadPreviousPeriodComparison()
        isLoading = false
    }
    
    /// 加载指定月的汇总（带缓存）
    func loadMonthSummaries(for month: Date) async {
        let key = month.startOfMonth
        if let cached = summaryCache[key] {
            dailySummaries = cached
            if currentMonth.startOfMonth == key { loadMonthlySummary() }
            return
        }
        do {
            let data = try await repository.getDailySummaries(for: key)
            summaryCache[key] = data
            if currentMonth.startOfMonth == key {
                dailySummaries = data
                loadMonthlySummary()
            }
        } catch {
            print("[CalendarState] 加载月汇总失败: \(error)")
        }
    }
    
    /// 加载选中日的交易 + 统计
    func loadSelectedDayData() async {
        do {
            let txns = try await repository.getTransactionsForDay(selectedDate)
            selectedDayTransactions = txns
            selectedDayExpense = txns.filter { $0.transactionType == .expense }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            selectedDayIncome = txns.filter { $0.transactionType == .income }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        } catch {
            print("[CalendarState] 加载日交易失败: \(error)")
        }
    }
    
    /// 数据变更后刷新（清缓存 + 重新加载）
    func refreshAfterDataChange() {
        summaryCache.removeAll()
        Task {
            await loadMonthSummaries(for: currentMonth)
            await loadSelectedDayData()
            await loadPreviousPeriodComparison()
        }
    }
    
    // MARK: - 月度汇总 & 环比

    /// 从已缓存的 dailySummaries 聚合当月总支出/收入
    func loadMonthlySummary() {
        var totalExpense: Decimal = 0
        var totalIncome: Decimal = 0
        for (_, summary) in dailySummaries {
            totalExpense += summary.totalExpense
            totalIncome += summary.totalIncome
        }
        currentMonthExpense = totalExpense
        currentMonthIncome = totalIncome
    }

    /// 计算上月同期对比（如 4.1-4.4 vs 3.1-3.4）
    func loadPreviousPeriodComparison() async {
        let cal = Calendar.current
        let dayIndex = cal.component(.day, from: selectedDate)

        let previousMonthStart = currentMonth.addingMonths(-1)
        let previousMonthDays = previousMonthStart.daysInMonth

        // 处理月份天数差异：如 3.31 vs 2.28 → 取 min(31, 28) = 28
        let effectiveDays = min(dayIndex, previousMonthDays)

        // 确保上月数据已缓存
        await loadMonthSummaries(for: previousMonthStart)

        let prevKey = previousMonthStart.startOfMonth
        guard let prevSummaries = summaryCache[prevKey] else {
            previousPeriodExpense = nil
            previousPeriodIncome = nil
            return
        }

        var prevExpense: Decimal = 0
        var prevIncome: Decimal = 0
        for dayOffset in 0..<effectiveDays {
            let date = previousMonthStart.addingDays(dayOffset)
            if let summary = prevSummaries[date] {
                prevExpense += summary.totalExpense
                prevIncome += summary.totalIncome
            }
        }

        previousPeriodExpense = prevExpense
        previousPeriodIncome = prevIncome
    }

    // MARK: - 内部
    
    private func loadMonthIfNeeded() {
        Task { await loadMonthSummaries(for: currentMonth) }
    }
}
