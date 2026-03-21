//
//  OverviewTabView.swift
//  Holo
//
//  总览 Tab 视图
//  包含柱状图 + TOP3 分类卡片
//

import SwiftUI

// MARK: - OverviewTabView

/// 总览 Tab 视图
struct OverviewTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    var onCategoryTap: ((Category) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                // 周期汇总卡片
                periodSummaryCard

                // 柱状图
                BarChartView(dataPoints: state.chartDataPoints)

                // TOP3 分类
                HStack(spacing: HoloSpacing.md) {
                    TopCategoryCard(
                        title: "支出 TOP 3",
                        aggregations: state.expenseCategoryAggregations,
                        accentColor: .holoError
                    ) { category in
                        onCategoryTap?(category)
                    }

                    TopCategoryCard(
                        title: "收入 TOP 3",
                        aggregations: state.incomeCategoryAggregations,
                        accentColor: .holoSuccess
                    ) { category in
                        onCategoryTap?(category)
                    }
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
    }

    // MARK: - 周期汇总卡片

    private var periodSummaryCard: some View {
        HStack(spacing: 0) {
            // 支出
            PeriodSummaryItem(
                title: "总支出",
                amount: state.periodSummary.formattedExpense,
                subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyExpense as NSDecimalNumber) ?? "¥0")",
                color: .holoError
            )

            Divider()
                .frame(height: 40)

            // 收入
            PeriodSummaryItem(
                title: "总收入",
                amount: state.periodSummary.formattedIncome,
                subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyIncome as NSDecimalNumber) ?? "¥0")",
                color: .holoSuccess
            )

            Divider()
                .frame(height: 40)

            // 净收入
            PeriodSummaryItem(
                title: "净收入",
                amount: state.periodSummary.formattedNetIncome,
                subtitle: "\(state.periodSummary.transactionCount) 笔",
                color: state.periodSummary.netIncome >= 0 ? .holoSuccess : .holoError
            )
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
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
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)

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
