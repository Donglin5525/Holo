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

            if data.isEmpty {
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
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(formatYAxis(doubleValue))
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
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
        case .sleep, .standHours:
            return String(format: "%.0f", value)
        }
    }

    // MARK: - Empty State

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
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