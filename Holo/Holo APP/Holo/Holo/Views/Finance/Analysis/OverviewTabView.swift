//
//  OverviewTabView.swift
//  Holo
//
//  总览 Tab 视图
//  包含柱状图 + TOP3 分类卡片
//  年档额外渲染：同比对照卡（今年 vs 上一个同口径年）、同比双柱图、年预算进度
//

import SwiftUI
import CoreData
import Charts

// MARK: - OverviewTabView

/// 总览 Tab 视图
struct OverviewTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    var onCategoryTap: ((Category) -> Void)? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 年档：同比对照卡（今年 vs 上一个同口径年，随口径切换基准；
                // 直选历史年后标题改用年份数字，不再自称「今年」）
                if state.isYearView {
                    YearOverYearSummaryCard(
                        current: state.periodSummary,
                        previous: state.previousPeriodSummary,
                        currentLabel: yearLabels.current,
                        previousLabel: yearLabels.previous
                    )
                }

                // 周期汇总卡片
                periodSummaryCard

                // 年档：支出同比双柱（今年 vs 上一个同口径年，按月/账期逐桶对照）
                if state.isYearView {
                    YearComparisonChartView(
                        points: state.yearComparisonPoints,
                        currentLabel: yearLabels.current,
                        previousLabel: yearLabels.previous
                    )
                }

                // 收支趋势：收支柱（下层）+ 余额线（上层）同画布分区
                //（项目维度下无余额语义，余额线与右轴整体隐藏）
                TrendChartView(dataPoints: state.chartDataPoints, showsBalanceLine: state.showsBalanceLine)

                // 年档 + 自然年口径 + 设有「每年」预算：年预算进度卡
                //（预算周期自身管理起止，一期只挂自然年口径，记账年视图下不显示）
                if state.isYearView && state.yearBasis == .calendar {
                    YearBudgetProgressCard()
                }

                // 账户排行：点行 = 只看该账户（排行随项目筛选切片，不受账户筛选影响）
                AccountRankingCard(
                    aggregations: state.accountAggregations,
                    selectedAccountId: state.selectedAccountId
                ) { accountId in
                    state.setAccountFilter(accountId)
                }

                // 项目排行：点行 = 只看该项目（无项目支出的月份整卡隐藏）
                FinanceProjectRankingCard(
                    aggregations: state.financeProjectAggregations,
                    selectedProjectId: state.selectedFinanceProjectId
                ) { projectId in
                    state.setFinanceProjectFilter(projectId)
                }

                // TOP3 分类
                TopCategoryCard(
                    expenseAggregations: state.expenseCategoryAggregations,
                    incomeAggregations: state.incomeCategoryAggregations
                ) { category in
                    onCategoryTap?(category)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
    }

    /// 年档同比标签（当前周期=今年，历史周期=年份数字）
    private var yearLabels: (current: String, previous: String) {
        state.yearComparisonLabels
    }

    /// 汇总卡头部的周期描述（与顶部日期选择器口径一致：range.end 是排他上界，减 1 秒显示）
    private var periodSubtitle: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(state.timeRange == .year ? "yMMMd" : "MMMd")
        return "\(formatter.string(from: state.currentDateRange.start)) - \(formatter.string(from: state.currentDateRange.end.addingTimeInterval(-1)))"
    }

    // MARK: - 周期汇总卡片

    private var periodSummaryCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 卡头与「收支趋势」「分类排行」同一套标题语言
            HStack(spacing: HoloSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("周期汇总")
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)

                    Text(periodSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: HoloSpacing.sm)

                Text("\(state.periodSummary.transactionCount) 笔")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }

            HStack(spacing: 0) {
                PeriodSummaryItem(
                    title: String(localized: "总支出"),
                    amount: state.periodSummary.formattedExpense,
                    subtitle: averageSubtitle(expense: true),
                    color: .holoError,
                    badge: yoyBadge(
                        current: state.periodSummary.totalExpense,
                        previous: state.previousPeriodSummary.totalExpense,
                        increaseIsNegative: false
                    )
                )

                Divider()
                    .opacity(0.4)
                    .frame(height: 40)

                PeriodSummaryItem(
                    title: String(localized: "总收入"),
                    amount: state.periodSummary.formattedIncome,
                    subtitle: averageSubtitle(expense: false),
                    color: .holoSuccess,
                    badge: yoyBadge(
                        current: state.periodSummary.totalIncome,
                        previous: state.previousPeriodSummary.totalIncome,
                        increaseIsNegative: true
                    )
                )

                Divider()
                    .opacity(0.4)
                    .frame(height: 40)

                PeriodSummaryItem(
                    title: String(localized: "净收入"),
                    amount: state.periodSummary.formattedNetIncome,
                    subtitle: "",
                    color: state.periodSummary.netIncome >= 0 ? .holoSuccess : .holoError,
                    badge: netIncomeBadge
                )
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    /// 均值副标题：年档给月均（看全年时日均没有信息量），其他档位保持日均
    private func averageSubtitle(expense: Bool) -> String {
        let value = expense
            ? (state.isYearView ? state.periodSummary.averageMonthlyExpense : state.periodSummary.averageDailyExpense)
            : (state.isYearView ? state.periodSummary.averageMonthlyIncome : state.periodSummary.averageDailyIncome)
        let prefix = state.isYearView
            ? String(localized: "月均")
            : String(localized: "日均")
        let amount = NumberFormatter.currency.string(from: value as NSDecimalNumber) ?? "¥0"
        return "\(prefix) \(amount)"
    }

    /// 同比 badge（年档专属）：▲/▼ 百分比；上期为 0 无基准时不显示
    private func yoyBadge(current: Decimal, previous: Decimal, increaseIsNegative: Bool) -> (text: String, color: Color)? {
        guard state.isYearView, previous > 0 else { return nil }
        let percentage = Double(truncating: ((current - previous) / previous * 100) as NSDecimalNumber)
        let arrow = percentage >= 0 ? "▲" : "▼"
        let color: Color = (percentage >= 0) == increaseIsNegative ? .holoSuccess : .holoError
        return ("\(arrow) \(String(format: "%.1f", abs(percentage)))%", color)
    }

    /// 净收入同比：带上基准称呼，回答「今年比去年多存/多花了多少」（历史年显示年份数字）
    private var netIncomeBadge: (text: String, color: Color)? {
        guard state.isYearView else { return nil }
        let current = state.periodSummary.netIncome
        let previous = state.previousPeriodSummary.netIncome
        let color: Color = current >= previous ? .holoSuccess : .holoError
        let diff = current - previous
        let amount = NumberFormatter.compactCurrency(abs(diff))
        return (String(localized: "较\(yearLabels.previous) \(diff >= 0 ? "+" : "-")\(amount)"), color)
    }
}

// MARK: - Period Summary Item

/// 周期汇总项
struct PeriodSummaryItem: View {
    let title: String
    let amount: String
    let subtitle: String
    let color: Color
    /// 同比小徽标（年档）：涨跌方向 + 颜色由调用方决定
    var badge: (text: String, color: Color)? = nil

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Text(amount)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }

            if let badge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(badge.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 年度同比对照卡

/// 年档第一卡：当前年 vs 上一个同口径年（支出/收入双行对比条 + 涨跌 badge）。
/// 看当前年显示「今年/上一个记账年(去年同期)」，看历史年显示年份数字（2025年 vs 2024年）。
struct YearOverYearSummaryCard: View {
    let current: PeriodSummary
    let previous: PeriodSummary
    var currentLabel: String = String(localized: "今年")
    var previousLabel: String = String(localized: "去年同期")

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(String(localized: "\(currentLabel) vs \(previousLabel)"))
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            comparisonRow(
                title: String(localized: "支出"),
                currentAmount: current.totalExpense,
                previousAmount: previous.totalExpense,
                upIsBad: true
            )

            comparisonRow(
                title: String(localized: "收入"),
                currentAmount: current.totalIncome,
                previousAmount: previous.totalIncome,
                upIsBad: false
            )
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    /// 一组对比：标题 + 涨跌 badge + 双行比例条
    @ViewBuilder
    private func comparisonRow(title: String, currentAmount: Decimal, previousAmount: Decimal, upIsBad: Bool) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack {
                Text(title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                if previousAmount > 0 {
                    let percentage = Double(truncating: ((currentAmount - previousAmount) / previousAmount * 100) as NSDecimalNumber)
                    let arrow = percentage >= 0 ? "▲" : "▼"
                    let color: Color = (percentage >= 0) == upIsBad ? .holoError : .holoSuccess
                    Text("\(arrow) \(String(format: "%.1f", abs(percentage)))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                } else {
                    Text(String(localized: "\(previousLabel)无记录"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            // 双行比例条铺在标题下方（overlay 避免嵌套 GeometryReader 撑高）
            VStack(alignment: .leading, spacing: 5) {
                progressBarRow(
                    label: currentLabel,
                    amount: currentAmount,
                    base: max(currentAmount, previousAmount),
                    color: .holoPrimary
                )
                progressBarRow(
                    label: previousLabel,
                    amount: previousAmount,
                    base: max(currentAmount, previousAmount),
                    color: .holoTextSecondary.opacity(0.4)
                )
            }
            .padding(.top, 26),
            alignment: .topLeading
        )
        .padding(.bottom, 44)
    }

    /// 比例行布局契约：左侧标签固定宽、右侧金额 fixedSize 永不截断，
    /// 条形只吃中间剩余宽度（旧版条形按「总宽-120」定宽把金额挤成「¥12…」）
    private func progressBarRow(label: String, amount: Decimal, base: Decimal, color: Color) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 64, alignment: .leading)

            GeometryReader { barGeo in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth(total: barGeo.size.width, amount: amount, base: base), height: 7)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text(NumberFormatter.compactCurrency(amount))
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(height: 14)
    }

    private func barWidth(total: CGFloat, amount: Decimal, base: Decimal) -> CGFloat {
        guard base > 0 else { return 4 }
        let ratio = Double(truncating: (amount / base) as NSDecimalNumber)
        return max(4, total * min(max(ratio, 0), 1))
    }
}

// MARK: - 年度同比双柱图

/// 年档支出同比：12 个周期桶，当前年（品牌色）vs 上一个同口径年（灰）成对柱；
/// 点柱查看单期对照详情；未来桶不画当前年柱（上年柱照画，避免「年底暴跌」错觉）
struct YearComparisonChartView: View {
    let points: [YearComparisonPoint]
    var currentLabel: String = String(localized: "今年")
    var previousLabel: String = String(localized: "上年")

    @State private var selectedIndex: Int?

    private var selectedIdx: Int? {
        if let selectedIndex, points.indices.contains(selectedIndex) {
            return selectedIndex
        }
        return points.lastIndex(where: { !$0.isFuture })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.lg) {
                Text(String(localized: "支出同比"))
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                legendDot(color: .holoError, label: currentLabel)
                legendDot(color: .holoTextSecondary.opacity(0.4), label: previousLabel)
            }

            if let idx = selectedIdx {
                detailRow(points[idx])
            }

            if points.isEmpty {
                Text(String(localized: "暂无数据"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.xl)
            } else {
                chartBody
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    // MARK: 图例

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: 选中详情行

    @ViewBuilder
    private func detailRow(_ point: YearComparisonPoint) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(point.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)

                    if let rangeText = point.rangeText {
                        Text(rangeText)
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }

                    if point.isOngoing {
                        Text(String(localized: "进行中"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.holoPrimary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(String(localized: "点击柱子查看单期对照"))
                    .font(.system(size: 9))
                    .foregroundColor(.holoTextPlaceholder)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(currentLabel) \(NumberFormatter.compactCurrency(point.current))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoError)

                if let percentage = point.changePercentage, !point.isFuture {
                    let arrow = percentage >= 0 ? "▲" : "▼"
                    let color: Color = percentage >= 0 ? .holoError : .holoSuccess
                    Text("\(previousLabel) \(NumberFormatter.compactCurrency(point.previous))  \(arrow) \(String(format: "%.1f", abs(percentage)))%")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(color)
                } else {
                    Text("\(previousLabel) \(NumberFormatter.compactCurrency(point.previous))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: 图表

    private var barValues: [Double] {
        points.flatMap { point -> [Double] in
            [Double(truncating: point.current as NSDecimalNumber),
             Double(truncating: point.previous as NSDecimalNumber)]
        }
    }

    private var yCeiling: Double {
        let maxValue = barValues.max() ?? 0
        guard maxValue > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(maxValue)))
        for step in [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] {
            let candidate = step * magnitude
            if candidate >= maxValue { return candidate }
        }
        return 10 * magnitude
    }

    private var chartBody: some View {
        let ceiling = yCeiling
        let domain: ClosedRange<Double> = -0.5...Double(max(points.count - 1, 0)) + 0.5

        return Chart {
            ForEach(points.indices, id: \.self) { index in
                let point = points[index]
                let isSelected = index == selectedIdx

                // 上年对照柱（上年数据全年存在，未来桶照画）
                if Double(truncating: point.previous as NSDecimalNumber) > 0 {
                    BarMark(
                        x: .value("期", Double(index) - 0.17),
                        yStart: .value("起点", 0.0),
                        yEnd: .value("金额", Double(truncating: point.previous as NSDecimalNumber)),
                        width: .fixed(5)
                    )
                    .cornerRadius(1.5)
                    .foregroundStyle(Color.holoTextSecondary.opacity(0.4))
                }

                // 今年柱（未来桶不画，避免零柱读成「暴跌」）
                let currentValue = Double(truncating: point.current as NSDecimalNumber)
                if !point.isFuture && currentValue > 0 {
                    BarMark(
                        x: .value("期", Double(index) + 0.17),
                        yStart: .value("起点", 0.0),
                        yEnd: .value("金额", currentValue),
                        width: .fixed(5)
                    )
                    .cornerRadius(1.5)
                    .foregroundStyle(
                        isSelected
                            ? Color.holoError
                            : Color.holoError.opacity(0.78)
                    )
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: xTickIndices) { value in
                AxisValueLabel {
                    if let axisValue = value.as(Double.self),
                       points.indices.contains(Int(axisValue.rounded())) {
                        let point = points[Int(axisValue.rounded())]
                        Text(point.label)
                            .font(.system(size: 9))
                            .foregroundStyle(
                                point.isFuture
                                    ? Color.holoTextPlaceholder.opacity(0.6)
                                    : Color.holoTextSecondary
                            )
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, ceiling * 0.5, ceiling]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.7))
                AxisValueLabel {
                    if let axisValue = value.as(Double.self) {
                        Text(Self.compactAmount(axisValue))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.holoTextPlaceholder)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .padding(.leading, 2)
                .padding(.trailing, 2)
        }
        .frame(height: 168)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // plotFrame 是 Anchor，需经 GeometryReader 解引用成 CGRect（与 TrendChartView 同画法）
                let plotFrame = proxy.plotFrame.map { geometry[$0] }

                DirectionalChartGestureOverlay(
                    onChanged: { location in
                        applySelection(location, plotFrame: plotFrame)
                    },
                    onEnded: { _ in },
                    onCancelled: {},
                    onTap: { location in
                        applySelection(location, plotFrame: plotFrame)
                    }
                )
            }
        }
    }

    /// X 轴稀疏刻度（12 桶全画太挤：每 2 期一格 + 末位）
    private var xTickIndices: [Double] {
        guard points.count > 1 else { return [] }
        var indices = Array(stride(from: 0, to: points.count - 1, by: 2).map(Double.init))
        let last = Double(points.count - 1)
        if !indices.contains(last) {
            indices.append(last)
        }
        return indices
    }

    private func applySelection(_ location: CGPoint, plotFrame: CGRect?) {
        // overlay 与图表同 frame；plotFrame 已解引用为 CGRect，location 直接减其 minX
        guard let plotFrame, plotFrame.width > 0, points.count > 1 else { return }
        let ratio = (location.x - plotFrame.minX) / plotFrame.width
        let index = Int((ratio * Double(points.count - 1)).rounded())
        guard points.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// 轴刻度金额紧凑口径（万 / 千 / 整数）
    private static func compactAmount(_ value: Double) -> String {
        if abs(value) < 1 { return value == 0 ? "0" : "" }
        if value >= 10_000 {
            return String(format: String(localized: "%.1f万"), value / 10_000)
        } else if value >= 1_000 {
            return String(format: String(localized: "%.1f千"), value / 1_000)
        }
        return String(format: "%.0f", value)
    }
}

// MARK: - 年预算进度卡

/// 年档专属：设了「每年」预算时显示进度（未设置不占位）
struct YearBudgetProgressCard: View {
    @State private var summary: GlobalBudgetSummary?

    var body: some View {
        Group {
            if let summary {
                cardBody(summary)
            }
        }
        .task {
            if summary == nil {
                summary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .year)
            }
        }
    }

    @ViewBuilder
    private func cardBody(_ summary: GlobalBudgetSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text(String(localized: "年预算 · 已用 \(Int(summary.progress * 100))%"))
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                if summary.isOverBudget {
                    Text(String(localized: "已超支"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoError)
                } else if summary.isWarning {
                    Text(String(localized: "接近上限"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoError.opacity(0.85))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoDivider.opacity(0.5))

                    Capsule()
                        .fill(
                            summary.isOverBudget
                                ? Color.holoError
                                : (summary.isWarning ? Color.holoError.opacity(0.85) : Color.holoPrimary)
                        )
                        .frame(width: max(4, geo.size.width * min(summary.progress, 1)))
                }
            }
            .frame(height: 8)

            HStack {
                Text(String(localized: "已用 \(NumberFormatter.compactCurrency(summary.totalSpentAmount))"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Text(String(localized: "预算 \(NumberFormatter.compactCurrency(summary.totalBudgetAmount))"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }
}

// MARK: - Preview

#Preview {
    OverviewTabView(state: FinanceAnalysisState())
}
