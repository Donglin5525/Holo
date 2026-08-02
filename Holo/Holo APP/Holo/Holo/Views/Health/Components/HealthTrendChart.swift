//
//  HealthTrendChart.swift
//  Holo
//
//  健康趋势柱状图组件
//  显示 7 天健康数据趋势
//

import SwiftUI
import Charts

// MARK: - HealthTrendChart

/// 健康趋势柱状图
struct HealthTrendChart: View {
    let data: [DailyHealthData]
    let type: HealthMetricType

    private var allValuesZero: Bool {
        data.allSatisfy { $0.value == 0 }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            HStack {
                Text("近 7 天趋势")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                if !data.isEmpty {
                    Text("平均: \(type.formatValue(averageValue)) \(type.unit)")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            if data.isEmpty || allValuesZero {
                emptyChartView
            } else {
                chartContent
            }
        }
        .frame(height: 140)
    }

    // MARK: - Computed Properties

    private var averageValue: Double {
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + $1.value } / Double(data.count)
    }

    // MARK: - Chart Content

    private var chartContent: some View {
        Chart(data) { item in
            BarMark(
                x: .value("日期", item.date, unit: .day),
                y: .value(type.unit, item.value)
            )
            .foregroundStyle(type.color.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 1)) { value in
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
                        Text(formatYAxis(doubleValue))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain, range: .plotDimension(startPadding: 9, endPadding: 12))
    }

    // MARK: - Y 轴范围

    /// Y 轴域：从 0 到 niceCeil(最大值)，与图表设计规范一致，避免轴抖动
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

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func formatYAxis(_ value: Double) -> String {
        switch type {
        case .steps:
            return String(format: "%.0f", value / 1000) + "k"
        case .sleep, .standHours, .activeMinutes:
            return String(format: "%.0f", value)
        }
    }

    // MARK: - Empty State

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无可用趋势数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview {
    let mockData: [DailyHealthData] = (0..<7).reversed().compactMap { offset in
        guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else {
            return nil
        }
        return DailyHealthData(date: date, value: Double.random(in: 5000...15000))
    }

    return HealthTrendChart(data: mockData, type: .steps)
        .padding()
        .background(Color.holoBackground)
}
