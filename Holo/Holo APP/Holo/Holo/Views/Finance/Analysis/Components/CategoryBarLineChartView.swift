//
//  CategoryBarLineChartView.swift
//  Holo
//
//  类别占比柱状图 + 折线图组合组件
//  柱状图显示金额（科目名称在柱体内），折线图显示占比百分比
//

import SwiftUI
import Charts

// MARK: - CategoryBarLineChartView

/// 类别占比柱状图 + 折线图组合视图
/// 柱状图显示金额，科目名称标注在柱体内部
/// 折线图显示占比百分比，在柱状图外侧区域展示，数据点与柱体垂直对齐
struct CategoryBarLineChartView: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    let onSelectCategory: ((Category?) -> Void)?

    // 图表颜色
    private let chartColors: [Color] = [
        .holoChart1, .holoChart2, .holoChart3, .holoChart4, .holoChart5
    ]

    /// 折线颜色
    private let lineColor: Color = .holoPrimary

    /// 最大金额（用于缩放折线数据）
    private var maxAmount: Double {
        let maxVal = aggregations.map { Double(truncating: $0.amount as NSDecimalNumber) }.max() ?? 1
        return max(maxVal, 1)
    }

    /// 折线 Y 轴缩放后的数据（将 0-100% 映射到 0-maxAmount）
    private var scaledPercentageData: [(agg: CategoryAggregation, scaledY: Double)] {
        aggregations.map { agg in
            let scaledY = (agg.percentage / 100.0) * maxAmount
            return (agg, scaledY)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if aggregations.isEmpty {
                emptyChartView
            } else {
                chartContent
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 图例
            chartLegend

            // 组合图表
            chartWithOverlay
        }
    }

    // MARK: - 图例

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: lineColor, label: "占比")
        }
    }

    // MARK: - 组合图表

    private var chartWithOverlay: some View {
        Chart {
            // 柱状图 - 金额
            ForEach(Array(aggregations.enumerated()), id: \.element.id) { index, agg in
                let amount = Double(truncating: agg.amount as NSDecimalNumber)
                BarMark(
                    x: .value("分类", agg.category.name),
                    y: .value("金额", amount)
                )
                .foregroundStyle(colorForIndex(index))
                .opacity(selectedCategory == nil || selectedCategory?.id == agg.category.id ? 0.85 : 0.3)
                .cornerRadius(4)
            }

            // 折线图 - 缩放后的占比
            ForEach(Array(scaledPercentageData.enumerated()), id: \.element.agg.id) { index, item in
                LineMark(
                    x: .value("分类", item.agg.category.name),
                    y: .value("占比", item.scaledY)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("分类", item.agg.category.name),
                    y: .value("占比", item.scaledY)
                )
                .foregroundStyle(lineColor)
                .symbolSize(40)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo.frame(in: .global)
                let localFrame = geo.frame(in: .local)

                // 右侧百分比轴标签
                rightAxisLabels(chartFrame: localFrame)

                // 每个柱体内部的分类名称 + 折线数据点的占比标注
                ForEach(Array(aggregations.enumerated()), id: \.element.id) { index, agg in
                    let amount = Double(truncating: agg.amount as NSDecimalNumber)
                    let scaledY = (agg.percentage / 100.0) * maxAmount

                    if let xPos = proxy.position(forX: agg.category.name),
                       let barTopY = proxy.position(forY: amount),
                       let lineY = proxy.position(forY: scaledY) {
                        let convertedX = xPos - plotFrame.minX
                        let convertedBarTopY = barTopY - plotFrame.minY
                        let convertedLineY = lineY - plotFrame.minY

                        // 柱体内部的分类名称
                        Text(agg.category.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                            .position(
                                x: convertedX,
                                y: min(convertedBarTopY + 16, localFrame.maxY - 10)
                            )

                        // 折线数据点的占比标注
                        Text(agg.formattedPercentage)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(lineColor)
                            .fixedSize()
                            .position(
                                x: convertedX,
                                y: max(convertedLineY - 14, 6)
                            )
                    }
                }
            }
        }
        .frame(height: chartHeight)
    }

    /// 根据类别数量动态计算图表高度
    private var chartHeight: CGFloat {
        let count = aggregations.count
        if count <= 3 { return 200 }
        if count <= 5 { return 240 }
        if count <= 8 { return 280 }
        return 320
    }

    // MARK: - 右侧百分比轴

    @ViewBuilder
    private func rightAxisLabels(chartFrame: CGRect) -> some View {
        // 在图表右侧显示百分比刻度
        let percentages = [0.0, 25.0, 50.0, 75.0, 100.0]

        let topPadding: CGFloat = 8
        let bottomPadding: CGFloat = 24
        let plotHeight = chartFrame.height - topPadding - bottomPadding

        ForEach(percentages, id: \.self) { pct in
            let normalizedY = pct / 100.0
            let yPos = chartFrame.maxY - bottomPadding - CGFloat(normalizedY) * plotHeight

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 8))
                .foregroundColor(.holoTextSecondary)
                .fixedSize()
                .position(x: chartFrame.maxX + 28, y: yPos)
        }
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.bar")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 辅助方法

    private func colorForIndex(_ index: Int) -> Color {
        chartColors[index % chartColors.count]
    }
}

// MARK: - Preview

#Preview("Category Bar Line Chart") {
    VStack {
        CategoryBarLineChartView(
            aggregations: [],
            selectedCategory: nil
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
