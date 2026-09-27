//
//  FinanceAnalysisState.swift
//  Holo
//
//  财务分析模块的状态管理
//  参考 CalendarState 模式实现
//

import SwiftUI
import Combine
import os.log

// MARK: - FinanceAnalysisState

/// 财务分析模块状态管理器
@MainActor
class FinanceAnalysisState: ObservableObject {

    private let logger = Logger(subsystem: "com.holo.app", category: "FinanceAnalysisState")

    // MARK: - 发布属性

    /// 当前选中的时间范围
    @Published var timeRange: TimeRange = .month

    /// 原始时间范围类型（用于导航时保持类型）
    @Published var originalTimeRange: TimeRange = .month

    /// 年档口径（自然年/记账年），选择记忆到下次进入；仅年档生效
    @Published var yearBasis: FinanceYearBasis = FinanceYearBasis.loadDefault()

    /// 自定义时间范围（仅当 timeRange == .custom 时使用）
    @Published var customDateRange: (start: Date, end: Date)?

    /// 时间范围内的所有交易
    @Published var transactions: [Transaction] = []

    /// 图表数据点（按粒度聚合）
    @Published var chartDataPoints: [ChartDataPoint] = []

    /// 上一个同口径年的汇总（年档同比对照；非年档为空汇总）
    @Published var previousPeriodSummary: PeriodSummary = .empty()

    /// 年档同比对照点（今年 vs 上一个同口径年，按月/账期逐桶；非年档为空）
    @Published var yearComparisonPoints: [YearComparisonPoint] = []

    /// 支出分类聚合
    @Published var expenseCategoryAggregations: [CategoryAggregation] = []

    /// 收入分类聚合
    @Published var incomeCategoryAggregations: [CategoryAggregation] = []

    /// 周期汇总数据
    @Published var periodSummary: PeriodSummary = .empty()

    /// 下钻选中的一级分类（用于类别 Tab 下钻）
    @Published var selectedTopCategory: Category?

    /// 下钻后的二级分类聚合
    @Published var drillDownAggregations: [CategoryAggregation] = []

    /// 是否正在加载
    @Published var isLoading: Bool = false

    /// 图表选中的数据点日期（用于明细 Tab 点击交互）
    @Published var selectedChartDate: Date?

    /// 明细 Tab 当前分类筛选（从 TOP3 等入口跳转时使用）
    @Published var selectedDetailCategory: Category?

    // MARK: - 私有属性

    private let repository = FinanceRepository.shared
    private var loadGate = FinanceAnalysisLoadGate()

    // MARK: - 计算属性

    /// 当前时间范围的实际起止日期
    var currentDateRange: (start: Date, end: Date) {
        // 优先使用自定义范围（包括导航后的范围）
        if let custom = customDateRange {
            return custom
        }
        // 年档按口径取区间（自然年/记账年）
        if timeRange == .year {
            return timeRange.yearDateRange(basis: yearBasis)
        }
        return timeRange.dateRange()
    }

    /// 是否处于年档（同比卡/月均口径/年预算卡的启用条件）
    var isYearView: Bool { timeRange == .year }

    /// 是否允许右翻到下一个周期：窗口末端已越过「现在」即视为当前/未来周期，禁用
    var canNavigateToNext: Bool {
        FinanceAnalysisNextGate.canNavigateNext(rangeEnd: currentDateRange.end, now: Date())
    }

    /// 年档同比标签：看当前周期（含今天）沿用「今年/上一个记账年」既有文案；
    /// 直选或翻到历史年改用年份数字——看 2025 年不应再自称「今年」。
    /// 记账年命名跟随「起始年」规则，上一年即起始年 - 1（12 个账期前）。
    var yearComparisonLabels: (current: String, previous: String) {
        let (start, end) = currentDateRange
        let now = Date()
        if start <= now && now < end {
            return (String(localized: "今年"), yearBasis.previousYearLabel)
        }
        let year = Calendar.current.component(.year, from: start)
        return ("\(year)年", "\(year - 1)年")
    }

    /// 年口径切换是否可用：记账起始日为 1 号时两种口径等价，不提供切换
    var yearBasisSwitchAvailable: Bool {
        !FinancePeriodSettings.shared.isNaturalMonth
    }

    /// 当前时间范围的天数
    var dayCount: Int {
        let (start, end) = currentDateRange
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: start, to: end)
        return max(components.day ?? 1, 1)
    }

    /// 当前图表粒度
    var chartGranularity: ChartGranularity {
        .from(dayCount: dayCount)
    }

    /// 是否处于下钻模式
    var isDrillingDown: Bool {
        selectedTopCategory != nil
    }

    /// 当前显示的分类聚合（根据下钻状态返回一级或二级）
    var currentCategoryAggregations: [CategoryAggregation] {
        if selectedTopCategory != nil {
            // 返回该一级分类下的二级分类聚合
            return drillDownAggregations
        }
        return expenseCategoryAggregations
    }

    // MARK: - 初始化

    init() {
        Task { await loadData() }
    }

    // MARK: - 时间范围操作

    /// 切换时间范围
    func setTimeRange(_ range: TimeRange) {
        guard timeRange != range else { return }
        timeRange = range
        originalTimeRange = range
        if range != .custom {
            customDateRange = nil
        }
        scheduleLoad()
    }

    /// 切换年档口径：持久化选择；年档在位时回到新口径的「当前年」并重算
    ///（口径变更后「今年」的定义变了，回跳当前年比平移历史年更符合预期）
    func setYearBasis(_ basis: FinanceYearBasis) {
        guard yearBasis != basis else { return }
        yearBasis = basis
        basis.persist()
        guard isYearView else { return }
        customDateRange = nil
        scheduleLoad()
    }

    /// 设置自定义时间范围
    func setCustomDateRange(start: Date, end: Date) {
        timeRange = .custom
        originalTimeRange = .custom
        customDateRange = (start, end)
        scheduleLoad()
    }

    /// 从 Agent 深度分析等外部入口设置时间范围。
    func applyDeepLink(_ link: FinanceAnalysisDeepLink) {
        timeRange = .custom
        originalTimeRange = .custom
        customDateRange = (link.start, link.end)
        selectedChartDate = nil
        selectedDetailCategory = nil
        scheduleLoad()
    }

    /// 导航到指定时间范围（保持原始类型）
    func navigateToRange(start: Date, end: Date) {
        customDateRange = (start, end)
        // 保持原始的 timeRange 类型，不设置为 .custom
        scheduleLoad()
    }

    /// 切换到相邻时间段。日期计算和页面加载统一由状态层处理，避免按钮连续点击时旧请求覆盖新选择。
    func navigate(_ direction: FinanceDateRangeNavigationDirection) {
        let range = currentDateRange
        guard let shifted = FinanceDateRangeNavigator.shiftedRange(
            start: range.start,
            end: range.end,
            timeRange: timeRange,
            direction: direction,
            yearBasis: yearBasis
        ) else { return }

        navigateToRange(start: shifted.start, end: shifted.end)
    }

    // MARK: - 数据加载

    /// 加载所有数据
    func loadData() async {
        let generation = loadGate.begin()
        isLoading = true
        let (start, end) = currentDateRange
        await loadData(generation: generation, start: start, end: end)
    }

    /// 在用户操作发生的当下就让旧请求失效，避免旧请求抢在新 Task 启动前回写页面。
    /// showsLoading=false 用于后台静默刷新：每条数据变更通知都切加载态的话，
    /// 整页会随同步节奏反复「内容→转圈→内容」规律闪烁（2026-09-08 真机实报）。
    private func scheduleLoad(showsLoading: Bool = true) {
        let generation = loadGate.begin()
        if showsLoading {
            isLoading = true
        }
        let (start, end) = currentDateRange
        Task {
            await loadData(generation: generation, start: start, end: end)
        }
    }

    private func loadData(generation: Int, start: Date, end: Date) async {
        do {
            // 加载交易数据
            let txns = try await repository.getTransactions(from: start, to: end)

            // 年档同比：拉上一个同口径年（本地库查询，两次串行取数毫秒级）
            var previousSummary = PeriodSummary.empty()
            var comparisonPoints: [YearComparisonPoint] = []
            if isYearView {
                let previousRange = BillingCycleCalculator.shiftedYearRange(
                    start: start,
                    end: end,
                    offset: -1,
                    basis: yearBasis,
                    startDay: FinancePeriodSettings.shared.billingCycleStartDay
                )
                if let prevTxns = try? await repository.getTransactions(from: previousRange.start, to: previousRange.end) {
                    previousSummary = computePeriodSummary(from: prevTxns, range: previousRange)
                    comparisonPoints = buildYearComparisonPoints(
                        currentTxns: txns,
                        previousTxns: prevTxns,
                        currentStart: start,
                        previousStart: previousRange.start,
                        end: end
                    )
                }
            }

            // 计算截止到时间范围起点的累计余额
            let balanceAtStart = repository.getCumulativeBalance(before: start)

            // 计算图表数据点（以累计余额为初始值）
            let points = computeChartDataPoints(
                from: txns,
                start: start,
                end: end,
                initialBalance: balanceAtStart
            )

            // 计算分类聚合
            let expenseAggregations = try await repository.getTopLevelCategoryAggregations(
                from: start, to: end, type: .expense
            )
            let incomeAggregations = try await repository.getTopLevelCategoryAggregations(
                from: start, to: end, type: .income
            )

            // 计算周期汇总（年档带已过周期数，供月均口径）
            let summary = computePeriodSummary(from: txns, range: (start, end))

            // 用户可能在等待期间继续切换月份；只允许最后一次选择更新界面。
            guard loadGate.accepts(generation) else { return }
            transactions = txns
            chartDataPoints = points
            previousPeriodSummary = previousSummary
            yearComparisonPoints = comparisonPoints
            expenseCategoryAggregations = expenseAggregations
            incomeCategoryAggregations = incomeAggregations
            periodSummary = summary

            // 清除下钻状态
            selectedTopCategory = nil
            drillDownAggregations = []

        } catch {
            if loadGate.accepts(generation) {
                logger.error("加载数据失败: \(error)")
            }
        }

        if loadGate.accepts(generation) {
            isLoading = false
        }
    }

    /// 刷新数据（数据变更后调用）：静默重载，只在数据变化时原位换新值，不切加载态
    func refresh() {
        scheduleLoad(showsLoading: false)
    }

    // MARK: - 下钻操作

    /// 进入下钻模式（查看一级分类下的二级分类）
    func drillDown(category: Category) {
        guard category.isTopLevel else { return }
        selectedTopCategory = category

        let (start, end) = currentDateRange
        Task {
            do {
                drillDownAggregations = try await repository.getSubCategoryAggregations(
                    parentId: category.id,
                    from: start,
                    to: end
                )
            } catch {
                    logger.error("下钻加载失败: \(error)")
                drillDownAggregations = []
            }
        }
    }

    /// 退出下钻模式
    func exitDrillDown() {
        selectedTopCategory = nil
        drillDownAggregations = []
    }

    /// 加载子科目聚合数据（不修改下钻状态，用于弹窗展示）
    func loadSubCategoryAggregations(for category: Category) async -> [CategoryAggregation] {
        let (start, end) = currentDateRange
        return (try? await repository.getSubCategoryAggregations(
            parentId: category.id,
            from: start,
            to: end
        )) ?? []
    }

    // MARK: - 图表交互

    /// 选中图表数据点
    func selectChartDate(_ date: Date?) {
        selectedChartDate = date
    }

    /// 选中明细分类筛选
    func selectDetailCategory(_ category: Category?) {
        selectedDetailCategory = category
        selectedChartDate = nil
    }

    /// 判断交易是否命中当前分类筛选
    func transaction(_ transaction: Transaction, matchesDetailCategory category: Category) -> Bool {
        guard transaction.transactionType == category.transactionType else { return false }
        guard let transactionCategory = transaction.category else { return false }

        if category.isTopLevel {
            return transactionCategory.id == category.id || transactionCategory.parentId == category.id
        }
        return transactionCategory.id == category.id
    }

    // MARK: - 私有方法

    /// 计算图表数据点（含累计余额，以 initialBalance 为起始值）
    private func computeChartDataPoints(
        from transactions: [Transaction],
        start: Date,
        end: Date,
        initialBalance: Decimal = 0
    ) -> [ChartDataPoint] {
        let calendar = Calendar.current
        let rangeDayCount = max(calendar.dateComponents([.day], from: start, to: end).day ?? 1, 1)
        let granularity = ChartGranularity.from(dayCount: rangeDayCount)

        var points: [ChartDataPoint] = []
        var current = start
        var runningBalance: Decimal = initialBalance

        while current < end {
            let next: Date?
            let label: String
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")

            switch granularity {
            case .hour:
                next = calendar.date(byAdding: .hour, value: 1, to: current)
                df.dateFormat = "HH"
                label = df.string(from: current)

            case .day:
                next = calendar.date(byAdding: .day, value: 1, to: current)
                df.dateFormat = "M/d"
                label = df.string(from: current)

            case .week:
                next = calendar.date(byAdding: .weekOfYear, value: 1, to: current)
                df.dateFormat = "M/d"
                label = df.string(from: current)

            case .month:
                next = calendar.date(byAdding: .month, value: 1, to: current)
                df.dateFormat = "M月"
                label = df.string(from: current)
            }

            guard let nextDate = next else { break }

            let periodTxns = transactions.filter { tx in
                tx.date >= current && tx.date < nextDate
            }

            // 收支轴：统计口径，排除对账调整流水（它不是真实消费）
            // 退款笔按负支出并入支出侧：余额轴 net 同步少减，等价于钱退回来了，口径自洽
            let statisticsTxns = periodTxns.filter { !$0.isReconciliationAdjustment }
            let expense = statisticsTxns
                .filter { $0.statisticsType == .expense }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

            let income = statisticsTxns
                .filter { $0.statisticsType == .income }
                .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

            // 余额轴：含对账调整流水（补差是真实余额变化，漏掉会导致余额曲线与真实余额断裂）
            var net = income - expense
            for tx in periodTxns where tx.isReconciliationAdjustment {
                net += tx.transactionType == .income
                    ? tx.amount.decimalValue
                    : -tx.amount.decimalValue
            }
            runningBalance += net

            points.append(ChartDataPoint(
                date: current,
                label: label,
                expense: expense,
                income: income,
                transactionCount: statisticsTxns.count,
                balance: runningBalance
            ))

            current = nextDate
        }

        return points
    }

    /// 计算周期汇总（收支统计口径，排除对账调整流水；退款笔按负支出冲减）。
    /// range 非空时附带已过周期数（年视图月均口径；非年档传 nil 走日均）。
    private func computePeriodSummary(
        from transactions: [Transaction],
        range: (start: Date, end: Date)? = nil
    ) -> PeriodSummary {
        let statisticsTxns = transactions.filter { !$0.isReconciliationAdjustment }
        let totalExpense = statisticsTxns
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        let totalIncome = statisticsTxns
            .filter { $0.statisticsType == .income }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        let days = max(dayCount, 1)
        let elapsedPeriods = range.map {
            BillingCycleCalculator.elapsedPeriodCount(from: $0.start, to: $0.end)
        } ?? 0

        return PeriodSummary(
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            transactionCount: statisticsTxns.count,
            averageDailyExpense: totalExpense / Decimal(days),
            averageDailyIncome: totalIncome / Decimal(days),
            dayCount: days,
            elapsedPeriodCount: elapsedPeriods
        )
    }

    /// 年档同比双柱数据：今年与上一个同口径年逐桶（月/账期）配对，支出侧口径
    ///（排除对账调整；退款按负支出冲减，与汇总卡同口径）。
    private func buildYearComparisonPoints(
        currentTxns: [Transaction],
        previousTxns: [Transaction],
        currentStart: Date,
        previousStart: Date,
        end: Date
    ) -> [YearComparisonPoint] {
        let calendar = Calendar.current
        let now = Date()
        let startDay = FinancePeriodSettings.shared.billingCycleStartDay
        let isBilling = yearBasis == .billing

        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "M月"

        let rangeFormatter = DateFormatter()
        rangeFormatter.dateFormat = "M/d"

        func bucketExpense(_ txns: [Transaction], from: Date, to: Date) -> Decimal {
            txns.filter {
                !$0.isReconciliationAdjustment && $0.date >= from && $0.date < to
                    && $0.statisticsType == .expense
            }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        }

        var points: [YearComparisonPoint] = []
        var cCursor = currentStart
        var pCursor = previousStart

        while cCursor < end, points.count < 12 {
            let cNext = BillingCycleCalculator.shiftedCycleStart(cCursor, startDay: startDay, offset: 1, calendar: calendar)
            let pNext = BillingCycleCalculator.shiftedCycleStart(pCursor, startDay: startDay, offset: 1, calendar: calendar)

            let rangeText: String? = isBilling
                ? "\(rangeFormatter.string(from: cCursor))–\(rangeFormatter.string(from: cNext.addingTimeInterval(-1)))"
                : nil

            points.append(YearComparisonPoint(
                label: labelFormatter.string(from: cCursor),
                rangeText: rangeText,
                current: bucketExpense(currentTxns, from: cCursor, to: cNext),
                previous: bucketExpense(previousTxns, from: pCursor, to: pNext),
                isFuture: calendar.startOfDay(for: cCursor) > now,
                isOngoing: now >= cCursor && now < cNext
            ))

            cCursor = cNext
            pCursor = pNext
        }
        return points
    }
}
