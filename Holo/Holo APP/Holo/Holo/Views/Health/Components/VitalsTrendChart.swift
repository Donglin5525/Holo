import SwiftUI
import Charts

/// 稀疏记录也画出真实点；每张图独立保存选择，缺失日期不填零。
struct VitalsTrendChart: View {
    let values: [(date: Date, value: Double)]
    let unit: String
    let baseline: Double?
    @State private var selectedDate: Date?

    private var selectedPoint: (date: Date, value: Double)? {
        guard let selectedDate else { return nil }
        return values.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var domain: ClosedRange<Double> {
        let low = values.map(\.value).min() ?? 0
        let high = values.map(\.value).max() ?? 1
        let padding = max((high - low) * 0.15, 0.5)
        return (low - padding)...(high + padding)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            if let point = selectedPoint {
                Text("\(dateText(point.date)) · \(String(format: "%.1f", point.value)) \(unit)")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Chart {
                ForEach(values, id: \.date) { point in
                    LineMark(x: .value("日期", point.date, unit: .day), y: .value("值", point.value))
                        .foregroundStyle(Color.holoChart4)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    PointMark(x: .value("日期", point.date, unit: .day), y: .value("值", point.value))
                        .foregroundStyle(Color.holoChart4)
                        .symbolSize(values.count <= 3 ? 32 : 12)
                }
                if let baseline {
                    RuleMark(y: .value("基线", baseline))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if let point = selectedPoint {
                    RuleMark(x: .value("日期", point.date, unit: .day))
                        .foregroundStyle(Color.holoToolBorder)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $selectedDate)
            .frame(height: 76)
            .accessibilityLabel(String(localized: "30 天趋势"))
            .accessibilityIdentifier("health.vitals.trend")
            .accessibilityValue(Text("\(values.count) 条记录"))
        }
    }
}
