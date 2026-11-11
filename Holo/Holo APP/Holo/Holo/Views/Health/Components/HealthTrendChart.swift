import SwiftUI

struct HealthTrendChart: View {
    let data: [DailyHealthData]
    let type: HealthMetricType
    var endingOn: Date = Date()
    /// 看板卡头已带「近 7 天 · 指标」标题时传 false，避免标题双写；详情页保持自带标题
    var showsTitle = true
    @State private var selection: String?
    private var average: Double? { DailyHealthData.averageValue(in: data) }
    private var buckets: [HoloChartBucket] {
        let end = Calendar.current.startOfDay(for: endingOn)
        let start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
        return HoloChartFormat.days(from: start, through: end, values: data.map { ($0.date, $0.value) })
    }
    /// 摘要不重复报均值——空闲读数已把日均显示为大数字，这里只说口径与覆盖天数
    private var summary: String {
        guard !data.isEmpty else { return String(localized: "未读取到可用数据") }
        return String(localized: "近 7 天日均 · \(data.count) 天有记录")
    }
    var body: some View {
        HoloChartFrame(title: showsTitle ? "近 7 天趋势" : "") {
            HoloBarChart(buckets: buckets,
                         series: [.init(id: type.rawValue, title: type.displayName, color: type.color)],
                         selection: $selection, height: 125, summary: summary,
                         summaryValues: [average],
                         valueText: { "\(type.formatValue($0)) \(type.unit)" },
                         slotTicks: buckets.indices.map { $0 })
        }
        .onChange(of: type) { _, _ in selection = nil }
    }
}
