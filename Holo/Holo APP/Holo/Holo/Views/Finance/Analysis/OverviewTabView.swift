//
//  OverviewTabView.swift
//  Holo
//
//  总览 Tab 视图
//  包含柱状图 + TOP3 分类卡片
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
                // 周期汇总卡片
                periodSummaryCard

                // 收支趋势：收支柱（下层）+ 余额线（上层）同画布分区
                TrendChartView(dataPoints: state.chartDataPoints)

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

    /// 汇总卡头部的周期描述（与顶部日期选择器口径一致：range.end 是排他上界，减 1 秒显示）
    private var periodSubtitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
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
                    title: "总支出",
                    amount: state.periodSummary.formattedExpense,
                    subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyExpense as NSDecimalNumber) ?? "¥0")",
                    color: .holoError
                )

                Divider()
                    .opacity(0.4)
                    .frame(height: 40)

                PeriodSummaryItem(
                    title: "总收入",
                    amount: state.periodSummary.formattedIncome,
                    subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyIncome as NSDecimalNumber) ?? "¥0")",
                    color: .holoSuccess
                )

                Divider()
                    .opacity(0.4)
                    .frame(height: 40)

                PeriodSummaryItem(
                    title: "净收入",
                    amount: state.periodSummary.formattedNetIncome,
                    subtitle: "",
                    color: state.periodSummary.netIncome >= 0 ? .holoSuccess : .holoError
                )
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }
}

// MARK: - Period Summary Item

/// 周期汇总项
struct PeriodSummaryItem: View {
    let title: String
    let amount: String
    let subtitle: String
    let color: Color

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

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview {
    OverviewTabView(state: FinanceAnalysisState())
}
