//
//  LineChartView.swift
//  Holo
//
//  折线图组件（用于明细 Tab）
//  使用 Swift Charts 实现，支持点击交互
//

import SwiftUI
import Charts

// MARK: - LineChartView

/// 折线图视图
struct LineChartView: View {
    let dataPoints: [ChartDataPoint]
    let selectedDate: Date?
    let onSelectDate: (Date?) -> Void

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
            // 支出折线
            LineMark(
                x: .value("日期", point.label),
                y: .value("支出", Double(truncating: point.expense as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoError)
            .interpolationMethod(.catmullRom)

            // 支出点
            PointMark(
                x: .value("日期", point.label),
                y: .value("支出", Double(truncating: point.expense as NSDecimalNumber))
            )
            .foregroundStyle(Color.holoError)
            .symbolSize(30)

            // 收入折线
            if point.income > 0 {
                LineMark(
                    x: .value("日期", point.label),
                    y: .value("收入", Double(truncating: point.income as NSDecimalNumber))
                )
                .foregroundStyle(Color.holoSuccess)
                .interpolationMethod(.catmullRom)

                // 收入点
                PointMark(
                    x: .value("日期", point.label),
                    y: .value("收入", Double(truncating: point.income as NSDecimalNumber))
                )
                .foregroundStyle(Color.holoSuccess)
                .symbolSize(30)
            }

            // 选中高亮
            if let selectedDate = selectedDate,
               Calendar.current.isDate(point.date, inSameDayAs: selectedDate) {
                let yEndValue = max(
                    Double(truncating: point.expense as NSDecimalNumber),
                    Double(truncating: point.income as NSDecimalNumber)
                ) * 1.1
                if yEndValue > 0 {
                    RectangleMark(
                        x: .value("日期", point.label),
                        yStart: .value("底部", 0),
                        yEnd: .value("顶部", yEndValue)
                    )
                    .foregroundStyle(Color.holoPrimary.opacity(0.1))
                }
            }
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                if let label: String = proxy.value(atX: x) {
                                    if let point = dataPoints.first(where: { $0.label == label }) {
                                        onSelectDate(point.date)
                                    }
                                }
                            }
                            .onEnded { _ in
                                // 保持选中状态
                            }
                    )
            }
        }
        .frame(height: 220)
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Line Chart") {
    let sampleData = [
        ChartDataPoint(date: Date(), label: "周一", expense: 150, income: 0, transactionCount: 3),
        ChartDataPoint(date: Date().addingDays(1), label: "周二", expense: 80, income: 500, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(2), label: "周三", expense: 200, income: 0, transactionCount: 5),
        ChartDataPoint(date: Date().addingDays(3), label: "周四", expense: 50, income: 100, transactionCount: 2),
        ChartDataPoint(date: Date().addingDays(4), label: "周五", expense: 300, income: 0, transactionCount: 4),
    ]

    VStack {
        LineChartView(
            dataPoints: sampleData,
            selectedDate: nil
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
