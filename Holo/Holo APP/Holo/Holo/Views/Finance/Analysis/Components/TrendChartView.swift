import SwiftUI

/// 收支与余额共用时间桶，各自保持真实数值轴，不再压缩尖峰或叠加双轴。
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]
    var showsBalanceLine: Bool = true
    @State private var selection: String?

    private var flowBuckets: [HoloChartBucket] {
        dataPoints.map { point in
            HoloChartBucket(id: String(point.date.timeIntervalSince1970), label: point.label,
                            detail: ChartTooltipDateLabel.string(for: point, points: dataPoints),
                            values: [Double(truncating: point.expense as NSDecimalNumber),
                                     Double(truncating: point.income as NSDecimalNumber)],
                            isFuture: point.date > Date() && !point.hasTransactions)
        }
    }
    private var balanceBuckets: [HoloChartBucket] {
        zip(flowBuckets, dataPoints).map { bucket, point in
            var result = bucket
            result.values = [Double(truncating: point.balance as NSDecimalNumber)]
            return result
        }
    }
    var body: some View {
        HoloChartFrame(title: showsBalanceLine ? "收支与余额" : "收支趋势", independent: true) {
            HoloBarChart(buckets: flowBuckets,
                         series: [.init(id: "expense", title: "支出", color: .holoError),
                                  .init(id: "income", title: "收入", color: .holoSuccess)],
                         selection: $selection, height: 160,
                         valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
            if showsBalanceLine {
                HoloLineChart(buckets: balanceBuckets, series: [.init(id: "balance", title: "余额", color: .holoChart1)],
                              selection: $selection, height: 80,
                              valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
            }
        }
    }
}
