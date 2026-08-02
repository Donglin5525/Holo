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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题
            Text("趋势变化")
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            if data.isEmpty {
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
            // 区域填充（先画，垫在最底层）
            AreaMark(
                x: .value("日期", item.date, unit: .day),
                yStart: .value("底部", yDomain.lowerBound),
                yEnd: .value(unit, item.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.holoPrimary.opacity(0.14),
                        Color.holoPrimary.opacity(0.005)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            // 折线
            LineMark(
                x: .value("日期", item.date, unit: .day),
                y: .value(unit, item.value)
            )
            .foregroundStyle(Color.holoPrimary)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))

            // 数据点
            PointMark(
                x: .value("日期", item.date, unit: .day),
                y: .value(unit, item.value)
            )
            .foregroundStyle(Color.holoPrimary)
            .symbolSize(25)
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
                        Text(formatValue(doubleValue))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartYScale(
            domain: yDomain,
            range: .plotDimension(startPadding: 9, endPadding: 12)
        )
    }

    // MARK: - Y 轴范围

    /// 根据数据范围计算 Y 轴区间：下界取整、上界用 niceCeil 取好看整数，避免轴抖动
    private var yDomain: ClosedRange<Double> {
        guard !data.isEmpty else { return 0...100 }

        let values = data.map(\.value)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100

        // 数据范围
        let range = maxVal - minVal

        // 下界：留 30% 余量使趋势更明显，但不超过 0（测量值一般非负）
        let padding = max(range * 0.3, range > 0 ? range * 0.1 : 1.0)
        let lower = max(minVal - padding, 0)
        let upper = niceCeil(maxVal + padding)

        return lower...upper
    }

    /// 向上取整到整齐的刻度值（10, 20, 50, 100, 200, 500, 1000 ...），与趋势图一致
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
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据，记一笔开始追踪吧！")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
