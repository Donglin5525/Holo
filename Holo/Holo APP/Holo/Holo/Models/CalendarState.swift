//
//  CalendarState.swift
//  Holo
//
//  日历模块的 ViewModel — 管理日期选择、月份切换、
//  弹窗展开收起、每日汇总缓存、交易列表加载
//

import SwiftUI
import Combine
import CoreData
import os

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

    private let logger = Logger(subsystem: "com.holo.app", category: "CalendarState")
    private let refreshSignposter = OSSignposter(subsystem: "com.holo.app", category: "PresentationRefresh")

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

    /// 渲染用有效明细：外部删除路径（如分类删除连查明细）落库后、刷新落地前，
    /// 数组会短暂残留已失效对象（managedObjectContext 已被清空），
    /// SwiftUI 渲染读其属性会强桥接崩溃（开发规范 13 节场景 C），消费方一律用本属性
    var liveDayTransactions: [Transaction] {
        selectedDayTransactions.filter { $0.managedObjectContext != nil }
    }
    
    /// 选中日期支出/收入
    @Published var selectedDayExpense: Decimal = 0
    @Published var selectedDayIncome: Decimal = 0

    /// 本月支出/收入总计
    @Published var currentMonthExpense: Decimal = 0
    @Published var currentMonthIncome: Decimal = 0

    /// 全库是否存在任何已发生交易（false = 从未记过账的新用户，空态才显示激活引导）
    @Published var hasAnyTransaction: Bool = true

    /// 上月同期对比值（nil 表示无数据）
    @Published var previousPeriodExpense: Decimal? = nil
    @Published var previousPeriodIncome: Decimal? = nil

    /// 加载状态
    @Published var isLoading: Bool = false
    
    // MARK: - 私有
    
    /// 缓存：key = 月首日，value = 月度 DailySummary
    private var summaryCache: [Date: [Date: DailySummary]] = [:]

    private let repository = FinanceRepository.shared
    private var isPresentationVisible = false
    private var isPresentationReady = false
    private var hasLoadedCalendar = false
    private var needsPresentationRefresh = true
    private var presentationRefreshTask: Task<Void, Never>?

    /// 财务数据变化通知订阅
    private var changeObserver: AnyCancellable?

    init() {
        // 与 FinanceView 同生命周期：账本不可见时也要记住变化，回到账本再刷新。
        changeObserver = NotificationCenter.default
            .publisher(for: .financeDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAfterDataChange()
            }
    }
    
    // MARK: - 日期操作
    
    /// 选中某一天（自动加载交易数据）
    func selectDate(_ date: Date) {
        // 跨月选日时必须重载该月汇总与环比，否则顶部"本月支出"卡残留上一个月的数字
        let monthChanged = !date.isSameMonth(as: currentMonth)
        selectedDate = date
        currentWeekStart = date.startOfWeek
        if monthChanged {
            currentMonth = date.startOfMonth
        }
        Task {
            if monthChanged {
                await loadMonthSummaries(for: currentMonth)
                await loadPreviousPeriodComparison()
            }
            await ensureWeekMonthsLoaded()
            await loadSelectedDayData()
        }
    }
    
    /// 翻月即换月上下文（2026-10-09 东林拍板）：选中新月同号日（无该号钳到月末）。
    /// 必须走 selectDate 统一跨月同步链（月汇总/环比/当日明细一次刷新）——
    /// 此前只改 currentMonth 不动 selectedDate，翻月后明细区停在旧月旧日期且
    /// 月历无选中格子指示（与习惯回顾日历 8375e34cc 同族脱钩）
    func goToNextMonth() { selectDate(selectedDate.shiftingToMonth(currentMonth.addingMonths(1))) }
    func goToPreviousMonth() { selectDate(selectedDate.shiftingToMonth(currentMonth.addingMonths(-1))) }
    
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
        isPresentationReady = true
        schedulePresentationRefresh()
        await presentationRefreshTask?.value
    }

    /// 周历可见 7 天可能横跨两个月：把两端月份的汇总都并入共享桶，
    /// 否则缺月一侧的日期金额显示为空（loadMonthSummaries 带缓存，重复调用无害）
    func ensureWeekMonthsLoaded() async {
        await loadMonthSummaries(for: currentWeekStart)
        await loadMonthSummaries(for: currentWeekStart.addingDays(6))
    }
    
    /// 加载指定月的汇总（带缓存；结果并入共享桶，不整桶替换）
    func loadMonthSummaries(for month: Date) async {
        let key = month.startOfMonth
        if summaryCache[key] != nil {
            if currentMonth.startOfMonth == key { loadMonthlySummary() }
            return
        }
        do {
            let data = try await repository.getDailySummaries(for: key)
            summaryCache[key] = data
            mergeSummaries(data, for: key)
        } catch {
            logger.error("加载月汇总失败: \(error)")
        }
    }

    /// 只替换该月在共享桶中的数据，保留相邻月份：
    /// 周历/月历的可见日期会跨月（如 9/28~10/4 那一周），整桶替换会让
    /// 跨月日的金额随加载顺序闪没（2026-10-01 东林实测），所以按月合并、共存于桶内
    private func mergeSummaries(_ data: [Date: DailySummary], for monthKey: Date) {
        let nextMonth = monthKey.addingMonths(1)
        var summaries = dailySummaries.filter { $0.key < monthKey || $0.key >= nextMonth }
        summaries.merge(data) { _, new in new }
        dailySummaries = summaries
        if currentMonth.startOfMonth == monthKey { loadMonthlySummary() }
    }
    
    /// 加载选中日的交易 + 统计
    func loadSelectedDayData() async {
        do {
            let txns = try await repository.getTransactionsForDay(selectedDate)
                .filter { !$0.isDeleted }
            selectedDayTransactions = txns
            // 统计口径：退款笔按负支出并入当日支出（冲到账当月当日），不进收入
            selectedDayExpense = txns.filter { $0.statisticsType == .expense }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
            selectedDayIncome = txns.filter { $0.statisticsType == .income }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        } catch {
            logger.error("加载日交易失败: \(error)")
        }
    }

    /// 保存链路等待同一轮展示刷新，避免和保存通知重复读取。
    func refreshData() async {
        refreshAfterDataChange()
        await presentationRefreshTask?.value
    }

    func refreshAfterDataChange() {
        needsPresentationRefresh = true
        schedulePresentationRefresh()
    }

    func setPresentationVisible(_ visible: Bool) {
        isPresentationVisible = visible
        schedulePresentationRefresh()
    }

    private func schedulePresentationRefresh() {
        guard isPresentationVisible, isPresentationReady, needsPresentationRefresh,
              presentationRefreshTask == nil else { return }
        let isFirstLoad = !hasLoadedCalendar
        presentationRefreshTask = Task { [weak self] in
            // 从首条通知起固定合并一次，连续变更也有机会及时展示。
            if !isFirstLoad { try? await Task.sleep(for: .milliseconds(40)) }
            guard let self else { return }
            defer { presentationRefreshTask = nil }
            while isPresentationVisible && needsPresentationRefresh {
                needsPresentationRefresh = false
                if !hasLoadedCalendar { isLoading = true }
                await reloadVisibleData()
                if !hasLoadedCalendar {
                    hasLoadedCalendar = true
                    isLoading = false
                }
            }
        }
    }

    private func reloadVisibleData() async {
        let interval = refreshSignposter.beginInterval("Ledger presentation refresh")
        defer { refreshSignposter.endInterval("Ledger presentation refresh", interval) }
        // 历史月份失效后按需读取，保留屏上数据直到新结果到达。
        summaryCache.removeAll()
        await loadMonthSummaries(for: currentMonth)
        await ensureWeekMonthsLoaded()
        // 月历最后一行可能显示下月的日期；周历未跨月时也要补齐这部分。
        if let lastDay = CalendarGridGenerator.generateGrid(for: currentMonth).last,
           !lastDay.isSameMonth(as: currentMonth) {
            await loadMonthSummaries(for: lastDay)
        }
        await loadSelectedDayData()
        await loadPreviousPeriodComparison()
        await loadHasAnyTransaction()
    }

    /// 刷新「是否记过账」标记（记下第一笔后翻转，空态引导随之消失）
    private func loadHasAnyTransaction() async {
        do {
            hasAnyTransaction = try await repository.hasAnyTransaction()
        } catch {
            logger.error("查询是否存在交易失败: \(error)")
        }
    }
    
    // MARK: - 月度汇总 & 环比

    /// 聚合当月总支出/收入（共享桶内可能并有多月数据，必须从当月缓存圈定）
    func loadMonthlySummary() {
        var totalExpense: Decimal = 0
        var totalIncome: Decimal = 0
        for (_, summary) in summaryCache[currentMonth.startOfMonth] ?? [:] {
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

}
