//
//  FinanceAnalysisState.swift
//  Holo
//
//  财务分析模块的状态管理
//  参考 CalendarState 模式实现
//

import SwiftUI
import Combine

// MARK: - FinanceAnalysisState

/// 财务分析模块状态管理器
@MainActor
class FinanceAnalysisState: ObservableObject {

    // MARK: - 发布属性

    /// 当前选中的时间范围
    @Published var timeRange: TimeRange = .month

    /// 自定义时间范围（仅当 timeRange == .custom 时使用）
    @Published var customDateRange: (start: Date, end: Date)?

    /// 时间范围内的所有交易
    @Published var transactions: [Transaction] = []

    /// 图表数据点（按粒度聚合）
    @Published var chartDataPoints: [ChartDataPoint] = []

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

    // MARK: - 私有属性

    private let repository = FinanceRepository.shared

    // MARK: - 计算属性

    /// 当前时间范围的实际起止日期
    var currentDateRange: (start: Date, end: Date) {
        if timeRange == .custom, let custom = customDateRange {
            return custom
        }
        return timeRange.dateRange()
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
        if let topCategory = selectedTopCategory {
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
        if range != .custom {
            customDateRange = nil
        }
        Task { await loadData() }
    }

    /// 设置自定义时间范围
    func setCustomDateRange(start: Date, end: Date) {
        timeRange = .custom
        customDateRange = (start, end)
        Task { await loadData() }
    }

    // MARK: - 数据加载

    /// 加载所有数据
    func loadData() async {
        isLoading = true

        let (start, end) = currentDateRange

        do {
            // 加载交易数据
            let txns = try await repository.getTransactions(from: start, to: end)
            transactions = txns

            // 计算图表数据点
            chartDataPoints = computeChartDataPoints(from: txns, start: start, end: end)

            // 计算分类聚合
            expenseCategoryAggregations = try await repository.getTopLevelCategoryAggregations(
                from: start, to: end, type: .expense
            )
            incomeCategoryAggregations = try await repository.getTopLevelCategoryAggregations(
                from: start, to: end, type: .income
            )

            // 计算周期汇总
            periodSummary = computePeriodSummary(from: txns)

            // 清除下钻状态
            selectedTopCategory = nil
            drillDownAggregations = []

        } catch {
            print("[FinanceAnalysisState] 加载数据失败: \(error)")
        }

        isLoading = false
    }

    /// 刷新数据（数据变更后调用）
    func refresh() {
        Task { await loadData() }
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
                print("[FinanceAnalysisState] 下钻加载失败: \(error)")
                drillDownAggregations = []
            }
        }
    }

    /// 退出下钻模式
    func exitDrillDown() {
        selectedTopCategory = nil
        drillDownAggregations = []
    }

    // MARK: - 图表交互

    /// 选中图表数据点
    func selectChartDate(_ date: Date?) {
        selectedChartDate = date
    }

    // MARK: - 私有方法

    /// 计算图表数据点
    private func computeChartDataPoints(
        from transactions: [Transaction],
        start: Date,
        end: Date
    ) -> [ChartDataPoint] {
        let calendar = Calendar.current
        let granularity = ChartGranularity.from(dayCount: dayCount)

        // 根据粒度生成时间点
        var points: [ChartDataPoint] = []
        var current = start

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
                df.dateFormat = "d"
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

            // 计算该时间段的交易统计
            let periodTxns = transactions.filter { tx in
                tx.date >= current && tx.date < nextDate
            }

            let expense = periodTxns
                .filter { $0.transactionType == .expense }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

            let income = periodTxns
                .filter { $0.transactionType == .income }
                .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

            points.append(ChartDataPoint(
                date: current,
                label: label,
                expense: expense,
                income: income,
                transactionCount: periodTxns.count
            ))

            current = nextDate
        }

        return points
    }

    /// 计算周期汇总
    private func computePeriodSummary(from transactions: [Transaction]) -> PeriodSummary {
        let totalExpense = transactions
            .filter { $0.transactionType == .expense }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        let totalIncome = transactions
            .filter { $0.transactionType == .income }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }

        let days = max(dayCount, 1)

        return PeriodSummary(
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            transactionCount: transactions.count,
            averageDailyExpense: totalExpense / Decimal(days),
            averageDailyIncome: totalIncome / Decimal(days),
            dayCount: days
        )
    }
}
