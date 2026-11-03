import SwiftUI

/// 自然日补齐后交给共享点线图；缺失日保持断线，单点仍可查看。
struct VitalsTrendChart: View {
    let values: [(date: Date, value: Double)]
    let unit: String
    let baseline: Double?
    @State private var selection: String?
    private var buckets: [HoloChartBucket] {
        let end = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -29, to: end) ?? end
        return HoloChartFormat.days(from: start, through: end, values: values.map { ($0.date, $0.value) })
    }
    var body: some View {
        HoloLineChart(buckets: buckets, series: [.init(id: "vital", title: "测量值", color: .holoChart4)],
                      selection: $selection, height: 90, baseline: baseline,
                      valueText: { "\(HoloChartFormat.number($0)) \(unit)" })
            .accessibilityIdentifier("health.vitals.trend")
    }
}
