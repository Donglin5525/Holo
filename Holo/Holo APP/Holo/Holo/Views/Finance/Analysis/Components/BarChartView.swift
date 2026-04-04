//
//  BarChartView.swift
//  Holo
//
//  柱状图组件（用于总览 Tab）
//  使用 Swift Charts 实现
//

import SwiftUI
import Charts

// MARK: - BarChartView

/// 柱状图视图（支出/收入对比）
struct BarChartView: View {
    let dataPoints: [ChartDataPoint]
    var onTapBar: ((Date) -> Void)? = nil

    private var allValuesZero: Bool {
        dataPoints.allSatisfy { $0.expense == 0 && $0.income == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 图例
            chartLegend

            // 图表
            if dataPoints.isEmpty || allValuesZero {
                emptyChartView
            } else {
                chartContent
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 图例

    private var chartLegend: some View {
        HStack(spacing: HoloSpacing.lg) {
            LegendItem(color: .holoError, label: "支出")
            LegendItem(color: .holoSuccess, label: "收入")
        }
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(dataPoints) { point in
            // 支出柱
            BarMark(
                x: .value("日期", point.label),
                y: .value("支出", Double(truncating: point.expense as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoError)
            .position(by: .value("类型", "支出"))

            // 收入柱
            BarMark(
                x: .value("日期", point.label),
                y: .value("收入", Double(truncating: point.income as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoSuccess)
            .position(by: .value("类型", "收入"))
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel()
                    .foregroundStyle(Color.holoTextSecondary)
            }
        }
        .chartYAxisLabel("金额 (¥)")
        .frame(height: 200)
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
}

// MARK: - Legend Item

/// 图例项
struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: HoloSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

// MARK: - Preview

#Preview("Bar Chart") {
    let sampleData = [
        ChartDataPoint(date: Date(), label: "周一", expense: 150, income: 0, transactionCount: 3),
        ChartDataPoint(date: Date().addingDays(1), label: "周二", expense: 80, income: 500, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(2), label: "周三", expense: 200, income: 0, transactionCount: 5),
        ChartDataPoint(date: Date().addingDays(3), label: "周四", expense: 50, income: 100, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(4), label: "周五", expense: 300, income: 0, transactionCount: 4),
    ]

    VStack {
        BarChartView(dataPoints: sampleData)
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
