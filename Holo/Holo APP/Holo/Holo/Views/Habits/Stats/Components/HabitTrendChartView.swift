//
//  HabitTrendChartView.swift
//  Holo
//
//  完成率趋势折线图组件
//  使用 Swift Charts 实现
//

import SwiftUI
import Charts

// MARK: - HabitTrendChartView

/// 完成率趋势折线图
struct HabitTrendChartView: View {
    let data: [DailyCompletionData]
    let selectedDate: Date?
    let onSelectDate: (Date?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            Text("完成率趋势")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            // 图表
            if data.isEmpty {
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
        Chart(data) { item in
            // 折线
            LineMark(
                x: .value("日期", item.date, unit: .day),
                y: .value("完成率", item.completionRate)
            )
            .foregroundStyle(Color.holoPrimary)
            .interpolationMethod(.catmullRom)

            // 数据点
            PointMark(
                x: .value("日期", item.date, unit: .day),
                y: .value("完成率", item.completionRate)
            )
            .foregroundStyle(Color.holoPrimary)
            .symbolSize(30)

            // 选中高亮
            if let selectedDate = selectedDate,
               Calendar.current.isDate(item.date, inSameDayAs: selectedDate) {
                RectangleMark(
                    x: .value("日期", item.date, unit: .day),
                    yStart: .value("底部", 0),
                    yEnd: .value("顶部", 100)
                )
                .foregroundStyle(Color.holoPrimary.opacity(0.1))
            }
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
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider)
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                if let date: Date = proxy.value(atX: x) {
                                    onSelectDate(date)
                                }
                            }
                            .onEnded { _ in
                                // 保持选中状态
                            }
                    )
            }
        }
        .frame(height: 180)
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
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Trend Chart") {
    let sampleData: [DailyCompletionData] = (0..<7).map { offset in
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        let rate = Double.random(in: 40...100)
        return DailyCompletionData(date: date, completionRate: rate)
    }

    VStack {
        HabitTrendChartView(
            data: sampleData,
            selectedDate: nil
        ) { _ in }
    }
    .padding()
    .background(Color.holoBackground)
}
