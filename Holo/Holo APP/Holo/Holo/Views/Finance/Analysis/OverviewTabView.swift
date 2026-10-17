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
                TrendChartView(dataPoints: state.chartDataPoints)

                // 年档 + 自然年口径 + 设有「每年」预算：年预算进度卡
                //（预算周期自身管理起止，一期只挂自然年口径，记账年视图下不显示）
                if state.isYearView && state.yearBasis == .calendar {
                    YearBudgetProgressCard()
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
        .background(Color.holoToolBackground)
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
                        .foregroundColor(.holoToolText)

                    Text(periodSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                }

                Spacer(minLength: HoloSpacing.sm)

                Text("\(state.periodSummary.transactionCount) 笔")
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
            }

            // 三列必须同构对齐：任一列行数不同就会被 HStack 垂直居中整体下坠
            //（净收入列无日均小字时标题/金额比左右两列低半行），顶部对齐 + 空槽占位钉死
            HStack(alignment: .top, spacing: 0) {
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
        .holoSurface()
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
/// 四行槽位（标题/金额/副标题/徽标）每行恒占位：某列缺「日均」或徽标时其余列不塌位，
/// 配合外层 HStack(.top) 保证三列的标题行与金额行各在同一水平线
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
                .foregroundColor(.holoToolTextSecondary)

            Text(amount)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
                .lineLimit(1)
                .opacity(subtitle.isEmpty ? 0 : 1)

            Text(badge?.text ?? " ")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(badge?.color ?? .clear)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
                .foregroundColor(.holoToolText)

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
        .holoSurface()
    }

    /// 一组对比：标题 + 涨跌 badge + 双行比例条
    @ViewBuilder
    private func comparisonRow(title: String, currentAmount: Decimal, previousAmount: Decimal, upIsBad: Bool) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack {
                Text(title)
                    .font(.holoLabel)
                    .foregroundColor(.holoToolTextSecondary)

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
                        .foregroundColor(.holoToolTextSecondary.opacity(0.7))
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
                    color: .holoToolTextSecondary.opacity(0.4)
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
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 64, alignment: .leading)

            HoloProgress(value: base > 0 ? Double(truncating: (amount / base) as NSDecimalNumber) : 0, color: color, lineWidth: 7).frame(height: 14)

            Text(NumberFormatter.compactCurrency(amount))
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.holoToolTextSecondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(height: 14)
    }


}

// MARK: - 年度同比双柱图

/// 年档支出同比：12 个周期桶，当前年（品牌色）vs 上一个同口径年（灰）成对柱；
/// 点柱查看单期对照详情；未来桶不画当前年柱（上年柱照画，避免「年底暴跌」错觉）
struct YearComparisonChartView: View {
    let points: [YearComparisonPoint]
    var currentLabel: String = String(localized: "今年")
    var previousLabel: String = String(localized: "上年")
    @State private var selection: String?

    var body: some View {
        HoloChartFrame(title: "支出同比", independent: true) {
            HoloBarChart(buckets: points.enumerated().map { index, point in
                HoloChartBucket(id: String(index), label: point.label,
                                values: [point.isFuture ? nil : Double(truncating: point.current as NSDecimalNumber),
                                         Double(truncating: point.previous as NSDecimalNumber)],
                                futureSeries: point.isFuture ? [0] : [])
            }, series: [.init(id: "current", title: currentLabel, color: .holoError),
                        .init(id: "previous", title: previousLabel, color: .holoToolTextSecondary)],
               selection: $selection, height: 160,
               valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
        }
        .onChange(of: currentLabel) { _, _ in selection = nil }
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
                    .foregroundColor(.holoToolText)

                Spacer()

                if summary.isOverBudget {
                    Text(String(localized: "已超支"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolError)
                } else if summary.isWarning {
                    Text(String(localized: "接近上限"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoError.opacity(0.85))
                }
            }

            HoloProgress(value: summary.progress, color: budgetProgressColor(summary.progress), lineWidth: 8)

            HStack {
                Text(String(localized: "已用 \(NumberFormatter.compactCurrency(summary.totalSpentAmount))"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)

                Spacer()

                Text(String(localized: "预算 \(NumberFormatter.compactCurrency(summary.totalBudgetAmount))"))
                    .font(.system(size: 10))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}

// MARK: - Preview

#Preview {
    OverviewTabView(state: FinanceAnalysisState())
}
