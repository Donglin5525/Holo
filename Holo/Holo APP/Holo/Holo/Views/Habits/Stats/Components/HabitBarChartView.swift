//
//  HabitBarChartView.swift
//  Holo
//
//  计数习惯柱状图组件
//  显示每日累计值
//

import SwiftUI
import Charts

// MARK: - HabitBarChartView

/// 计数习惯柱状图
struct HabitBarChartView: View {
    let data: [DailyHabitData]
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题
            Text("每日\(unit)")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            if data.isEmpty {
                emptyChartView
            } else {
                chartContent
            }
        }
        .frame(height: 120)
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(data) { item in
            BarMark(
                x: .value("日期", item.date, unit: .day),
                y: .value("值", item.value)
            )
            .foregroundStyle(Color.holoPrimary.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisCount)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatDate(date))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartXScale(range: .plotDimension(startPadding: 12, endPadding: 12))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(String(format: "%.0f", doubleValue))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
    }

    // MARK: - Y 轴范围

    /// Y 轴域：从 0 到 niceCeil(最大值)，与趋势图规范一致，避免轴抖动
    private var yDomain: ClosedRange<Double> {
        let maxVal = data.map(\.value).max() ?? 0
        return 0...niceCeil(maxVal)
    }

    /// 向上取整到整齐的刻度值（10, 20, 50, 100, 200, 500, 1000 ...）
    private func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let niceFraction: Double
        switch fraction {
        case ...1: niceFraction = 1
        case ...2: niceFraction = 2
        case ...5: niceFraction = 5
        default: niceFraction = 10
        }
        return niceFraction * magnitude
    }

    // MARK: - X 轴标签数量

    private var xAxisCount: Int {
        let count = data.count
        if count <= 7 { return count }
        if count <= 14 { return 7 }
        if count <= 30 { return 6 }
        return 5
    }

    // MARK: - 日期格式化

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据，记一笔开始追踪吧！")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
