import SwiftUI

struct HealthTrendChart: View {
    let data: [DailyHealthData]
    let type: HealthMetricType
    var endingOn: Date = Date()
    @State private var selection: String?
    private var buckets: [HoloChartBucket] {
        let end = Calendar.current.startOfDay(for: endingOn)
        let start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
        return HoloChartFormat.days(from: start, through: end, values: data.map { ($0.date, $0.value) })
    }
    private var summary: String {
        guard !data.isEmpty else { return "未读取到可用数据" }
        let mean = data.reduce(0) { $0 + $1.value } / Double(data.count)
        return "平均 \(type.formatValue(mean)) \(type.unit) · \(data.count) 天有效记录"
    }
    var body: some View {
        HoloChartFrame(title: "近 7 天趋势") {
            HoloBarChart(buckets: buckets,
                         series: [.init(id: type.rawValue, title: type.displayName, color: type.color)],
                         selection: $selection, height: 125, summary: summary,
                         summaryValues: [data.isEmpty ? nil : data.reduce(0) { $0 + $1.value } / Double(data.count)],
                         valueText: { "\(type.formatValue($0)) \(type.unit)" })
        }
        .onChange(of: type) { _, _ in selection = nil }
    }
}
