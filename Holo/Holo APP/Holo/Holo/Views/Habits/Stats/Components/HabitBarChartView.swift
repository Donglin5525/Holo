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

    private var allValuesZero: Bool {
        data.allSatisfy { $0.value == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("每日\(unit)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            if data.isEmpty || allValuesZero {
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
                        Text(String(format: "%.0f", doubleValue))
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartXAxisLabel("")
        .chartYAxisLabel(unit)
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
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
