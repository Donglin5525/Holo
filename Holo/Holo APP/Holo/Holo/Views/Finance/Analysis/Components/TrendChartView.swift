import SwiftUI

/// 收支与余额共用时间桶，各自保持真实数值轴，不再压缩尖峰或叠加双轴。
/// 下钻页复用同一张卡做联动：selectedDate 把列表侧选中日同步到图上，
/// onScrubDate 把图上点选/滑动回传定位列表（选日即定位，实时生效）。
/// 不传（总览/项目/账户页签）时行为与之前完全一致。
/// 卡头不挂「查看明细」：选日瞬间列表已定位，按钮再点必是空动作，
/// 2026-10-30 东林实报「点击没反应」后移除（套件能力保留，任务统计页仍在用）。
struct TrendChartView: View {
    let dataPoints: [ChartDataPoint]
    var showsBalanceLine: Bool = true
    var selectedDate: Date? = nil
    var onScrubDate: ((Date) -> Void)? = nil
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

    private func date(ofBucketID id: String) -> Date? {
        dataPoints.first { String($0.date.timeIntervalSince1970) == id }?.date
    }

    var body: some View {
        HoloChartFrame(title: showsBalanceLine ? "收支与余额" : "收支趋势", independent: true) {
            HoloBarChart(buckets: flowBuckets,
                         series: [.init(id: "expense", title: "支出", color: .holoError),
                                  .init(id: "income", title: "收入", color: .holoSuccess)],
                         selection: $selection, height: 160,
                         valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" },
                         onInspect: { bucket in
                             if let date = date(ofBucketID: bucket.id) { onScrubDate?(date) }
                         })
            if showsBalanceLine {
                HoloLineChart(buckets: balanceBuckets, series: [.init(id: "balance", title: "余额", color: .holoChart1)],
                              selection: $selection, height: 80,
                              valueText: { NumberFormatter.currency.string(from: NSNumber(value: $0)) ?? "—" })
            }
        }
        .onChange(of: selectedDate) { _, date in
            if let date, let point = dataPoints.last(where: { $0.date <= date }) {
                selection = String(point.date.timeIntervalSince1970)
            } else { selection = nil }
        }
    }
}
