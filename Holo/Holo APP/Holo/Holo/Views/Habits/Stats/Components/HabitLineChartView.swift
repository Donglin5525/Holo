//
//  HabitLineChartView.swift
//  Holo
//
//  测量习惯折线图组件
//  显示趋势变化曲线
//

import SwiftUI
import Charts

// MARK: - HabitLineChartView

/// 测量习惯折线图
struct HabitLineChartView: View {
    let data: [DailyHabitData]
    let unit: String

    private var allValuesZero: Bool {
        data.allSatisfy { $0.value == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("趋势变化")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            if data.isEmpty || allValuesZero {
                emptyChartView
            } else {
                chartContent
            }
        }
        .frame(height: 150)
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(data) { item in
            // 折线
            LineMark(
                x: .value("日期", item.date, unit: .day),
                y: .value(unit, item.value)
            )
            .foregroundStyle(Color.holoPrimary)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

            // 数据点
            PointMark(
                x: .value("日期", item.date, unit: .day),
                y: .value(unit, item.value)
            )
            .foregroundStyle(Color.holoPrimary)
            .symbolSize(25)

            // 区域填充
            AreaMark(
                x: .value("日期", item.date, unit: .day),
                yStart: .value("底部", yDomain.lowerBound),
                yEnd: .value(unit, item.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.holoPrimary.opacity(0.3),
                        Color.holoPrimary.opacity(0.05)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisCount)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatDate(date))
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(formatValue(doubleValue))
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxisLabel("")
        .chartYAxisLabel(unit)
    }

    // MARK: - Y 轴范围

    /// 根据数据范围计算紧凑的 Y 轴区间，使趋势变化更明显
    private var yDomain: ClosedRange<Double> {
        guard !data.isEmpty else { return 0...100 }

        let values = data.map(\.value)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100

        // 数据范围
        let range = maxVal - minVal

        // 上下各留 30% 的余量（占数据范围的 30%），使趋势更陡峭
        let padding = max(range * 0.3, range > 0 ? range * 0.1 : 1.0)
        let lower = minVal - padding
        let upper = maxVal + padding

        return lower...upper
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

    // MARK: - 格式化值

    private func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
